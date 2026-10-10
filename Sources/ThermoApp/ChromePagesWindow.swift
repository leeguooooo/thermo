import AppKit
import CleanKit
import SwiftUI
import ThermoL10n

/// "View pages" on a browser's row in the Overview: measures every page twice, a minute apart, and
/// lists the ones that grow, the biggest, duplicate tabs, busy workers and hidden automation pages,
/// each with what to do. Pages are only closed one at a time, after asking.
@MainActor
final class ChromePagesModel: ObservableObject {
    let app: String
    var appMemoryKB: Int?
    var gpuKB: Int?
    @Published var phase: ChromeInspector.Phase?
    @Published var diagnosis: ChromeInspector.Diagnosis?
    @Published var closing: String?
    @Published var closeFailed: String?
    @Published private(set) var resultsStale = false
    private var task: Task<Void, Never>?
    private var generation = UUID()
    @Published private(set) var stopped = false

    init(app: String, appMemoryKB: Int?, gpuKB: Int?) {
        self.app = app; self.appMemoryKB = appMemoryKB; self.gpuKB = gpuKB
    }

    var running: Bool { task != nil }
    /// Whether the running (or last) check measures pages, rather than only listing tabs.
    @Published private(set) var measuring = false
    /// Memory per page is possible (chrome-use or a debugging port).
    var canMeasure: Bool { ChromeInspector.endpoint(app: app) != nil }

    /// Without `measure`, only the tab list: nothing is attached. Measuring attaches to each page
    /// (Chrome shows "is being debugged" briefly), so it starts only from the user's button.
    func start(measure: Bool = false, watch: TimeInterval = 60) {
        guard closing == nil else { return }
        stop()
        let generation = UUID()
        self.generation = generation
        stopped = false
        phase = .listingTabs
        measuring = measure
        let app = app, memory = appMemoryKB, gpu = gpuKB, model = self
        task = Task { [weak self] in
            let d = await ChromeInspector.diagnose(app: app, measure: measure, watch: watch, appMemoryKB: memory, gpuKB: gpu) { phase in
                Task { @MainActor in
                    guard model.generation == generation, !model.stopped else { return }
                    model.phase = phase
                }
            }
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            self.generation = UUID()
            self.diagnosis = d
            self.resultsStale = false
            self.closeFailed = nil
            self.phase = nil
            self.task = nil
        }
    }

    func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
        phase = nil
        measuring = false
        stopped = true
    }

    /// Closes one tab showing this address; on success it disappears from the lists.
    func close(url: String, title: String) {
        guard closing == nil, !running else { return }
        closing = url
        closeFailed = nil
        let app = app
        Task.detached {
            let ok = ChromeInspector.close(url: url, title: title, app: app)
            await MainActor.run {
                self.closing = nil
                guard ok, var d = self.diagnosis else {
                    if !ok { self.closeFailed = tr("%1$@ did not close the tab. Thermo may need permission in System Settings → Privacy & Security → Automation.", app) }
                    return
                }
                self.resultsStale = d.mode == .devtools
                d = Self.removingClosedPage(from: d, url: url, title: title)
                self.diagnosis = d
            }
        }
    }
    static func removingClosedPage(from diagnosis: ChromeInspector.Diagnosis, url: String, title: String) -> ChromeInspector.Diagnosis {
        var d = diagnosis
        if var tabs = d.tabs {
            if let index = tabs.lastIndex(where: { $0.url == url && $0.title == title }) ?? tabs.lastIndex(where: { $0.url == url }) {
                tabs.remove(at: index)
            }
            d.tabs = tabs
            d.duplicates = ChromeInspector.duplicates(tabs)
        }
        if var report = d.report {
            let matching = report.pages.filter { $0.url == url && $0.title == title }
            let candidates = matching.isEmpty ? report.pages.filter { $0.url == url } : matching
            // AppleScript cannot identify which DevTools target was closed when address and title repeat.
            // Keep the measured snapshot rather than subtracting an arbitrary page's heap.
            guard candidates.count <= 1 else { d.gap = nil; return d }
            if let index = report.pages.lastIndex(where: { $0.url == url && $0.title == title }) ?? report.pages.lastIndex(where: { $0.url == url }) {
                let removed = report.pages.remove(at: index)
                report.leaking.removeAll { $0.id == removed.id }
                report.largest = Array(report.pages.filter { $0.leak == nil }.prefix(5))
                report.pagesHeapMB = report.pages.reduce(0) { $0 + $1.heapMB }
                report.duplicates = report.duplicates.compactMap { duplicate in
                    var duplicate = duplicate
                    duplicate.count = report.pages.filter { $0.url == duplicate.url }.count
                    return duplicate.count > 1 ? duplicate : nil
                }
                d.duplicates = report.duplicates
            }
            d.report = report
            // The whole-browser footprint was measured before the close; do not imply it is current.
            d.gap = nil
        }
        return d
    }

}

struct ChromePagesView: View {
    @ObservedObject var model: ChromePagesModel
    /// Inside the main window: on its gradient, rows on glass, the list loads when shown.
    var embedded = false
    @State private var confirming: Target?

    struct Target: Identifiable { let url: String; let title: String; var id: String { url + "\u{0}" + title } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(embedded ? 32 : 14).padding(.top, embedded ? 16 : 0)
                .frame(maxWidth: embedded ? 884 : .infinity).frame(maxWidth: .infinity)
            if !embedded { Divider() }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.running { progress }
                    if let d = model.diagnosis { content(d) } else if !model.running { progress }
                }
                .padding(embedded ? 32 : 14).padding(.top, embedded ? -16 : 0)
                .frame(maxWidth: embedded ? 820 : .infinity, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: embedded ? .center : .leading)
            }
        }
        .background(embedded ? Color.clear : Color(nsColor: .windowBackgroundColor))
        .onAppear { if embedded && model.diagnosis == nil && !model.running { model.start() } }
        .onDisappear { if model.running { model.stop() } }
        .sheet(item: $confirming) { t in
            ConfirmSheet(title: tr("Close this page?"),
                         summary: tr("The tab is closed in %1$@, like clicking its ×. Anything typed into it and not saved is lost.", model.app),
                         destructive: true, heading: tr("Page"),
                         lines: [t.title.isEmpty ? t.url : t.title, t.url],
                         footnote: tr("Thermo only reads each page's memory, title and address, never its content, and closes nothing on its own."),
                         confirmTitle: tr("Close page"),
                         confirm: { confirming = nil; model.close(url: t.url, title: t.title) }, cancel: { confirming = nil })
        }
    }

    var header: some View {
        HStack(alignment: embedded ? .bottom : .center, spacing: 10) {
            if embedded {
                // The main window's page title, like every other page there.
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("Browser pages")).font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
                    Text(tr("Which %1$@ page is the problem", model.app) + " · " + summary).font(.callout).foregroundStyle(.white.opacity(0.6))
                }
            } else {
                Image(systemName: "rectangle.stack").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Which %1$@ page is the problem", model.app)).font(.headline)
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.running {
                Button(tr("Stop")) { model.stop() }.controlSize(.small)
            } else if model.canMeasure {
                Button(model.diagnosis?.mode == .devtools ? tr("Measure again") : tr("Measure memory")) { model.start(measure: true) }
                    .controlSize(.small).buttonStyle(.borderedProminent).disabled(model.closing != nil)
            } else {
                Button(tr("Check again")) { model.start() }.controlSize(.small).disabled(model.closing != nil || model.running)
            }
        }
    }

    var summary: String {
        if model.running { return model.measuring ? tr("Measuring every page twice, a minute apart, to see which ones grow.") : tr("Listing tabs…") }
        guard let d = model.diagnosis else {
            if model.stopped { return tr("Check stopped. You can start again when ready.") }
            return model.measuring ? tr("Measuring every page twice, a minute apart, to see which ones grow.") : tr("Listing tabs…")
        }
        switch d.mode {
        case .devtools:
            guard let r = d.report else { return "" }
            return tr("%1$@ pages, %2$@ workers · JavaScript %3$@", String(r.pages.count), String(r.workerCount), mb(r.pagesHeapMB + r.workersHeapMB))
        case .tabs:
            let tabs = d.tabs ?? []
            return tr("%1$@ tabs in %2$@ windows", String(tabs.count), String(Set(tabs.map(\.window)).count))
        case .unavailable:
            return tr("Could not look inside %1$@.", d.app)
        }
    }

    var progress: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.phase {
            case .measuring(let round, let done, let total):
                Text(tr("Measuring pages (%1$@/%2$@): %3$@ of %4$@", String(round), "2", String(done), String(total))).font(.callout)
                ProgressView(value: Double(done), total: Double(max(total, 1)))
            case .waiting(let left):
                Text(tr("Waiting %1$@ s to see which pages grow…", String(left))).font(.callout)
                ProgressView(value: 60 - Double(left), total: 60)
            case .listingTabs:
                Text(tr("Listing tabs…")).font(.callout)
                ProgressView()
            case nil:
                if model.stopped {
                    Label(tr("Check stopped. You can start again when ready."), systemImage: "pause.circle")
                        .font(.callout).foregroundStyle(.secondary)
                    Button(tr("Check again")) { model.start() }
                } else {
                    ProgressView()
                }
            }
            if model.measuring { Text(ChromeInspector.debuggingBarNote).font(.caption).foregroundStyle(.orange) }
            Text(tr("Thermo only reads each page's memory, title and address, never its content, and closes nothing on its own."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    func content(_ d: ChromeInspector.Diagnosis) -> some View {
        if let failed = model.closeFailed { note(failed, color: .red) }
        if model.resultsStale {
            note(tr("Page closed. Memory figures are from the previous check; measure again to update them."), color: .orange)
        }
        if d.mode == .tabs && model.canMeasure && !model.measuring {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("Which page leaks or uses the most memory? Measure every page twice, a minute apart.")).font(.callout)
                Text(ChromeInspector.debuggingBarNote).font(.caption).foregroundStyle(.secondary)
                Button(tr("Measure memory")) { model.start(measure: true) }.controlSize(.small).buttonStyle(.borderedProminent)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
        }
        if let h = d.hiddenText { note(h, color: .orange) }
        if let g = d.gap { note(g, color: .secondary) }
        if let r = d.report {
            if r.seconds != nil {
                section(tr("Growing"), r.leaking.isEmpty ? tr("No page grew in %1$@ s.", String(Int((r.seconds ?? 0).rounded()))) : nil) {
                    ForEach(r.leaking) { p in pageRow(p, warn: true) }
                }
            }
            section(tr("Largest"), nil) {
                ForEach(r.largest) { p in pageRow(p, warn: false) }
            }
        }
        if !d.duplicates.isEmpty {
            section(tr("Open more than once"), tr("Each copy uses its own memory. Close the ones you don't need.")) {
                ForEach(d.duplicates) { x in
                    row(title: x.title, url: x.url, trailing: "×\(x.count)", detail: nil, warn: false, closeTitle: tr("Close one"))
                }
            }
        }
        if let r = d.report, !r.workers.isEmpty {
            section(tr("Workers"), tr("Background scripts a site keeps running; they close with the site's tabs.")) {
                ForEach(r.workers.prefix(5)) { w in
                    HStack {
                        Text(tr("%1$@ runs %2$@ workers", w.site, String(w.count))).font(.callout)
                        Spacer()
                        if w.heapMB >= 1 { Text(mb(w.heapMB)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        if let h = d.hint {
            VStack(alignment: .leading, spacing: 6) {
                note(h, color: .secondary)
                if d.mode != .devtools && d.app == "Google Chrome" {
                    Button(tr("Copy install command")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ChromeInspector.chromeUseInstall, forType: .string)
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    func section<C: View>(_ title: String, _ caption: String?, @ViewBuilder _ rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
            rows()
        }
    }

    func pageRow(_ p: ChromeInspector.Page, warn: Bool) -> some View {
        let growth = p.growth.flatMap { g -> String? in
            guard warn else { return nil }
            return tr("%1$@ MB · %2$@ listeners · %3$@ nodes", String(format: "%+.1f", g.heapMB), String(format: "%+d", g.listeners), String(format: "%+d", g.nodes))
        }
        let detail = [growth, warn ? p.advice : tr("%1$@ nodes", String(p.nodes))].compactMap { $0 }.joined(separator: "\n")
        return row(title: p.title, url: p.url, trailing: mb(p.heapMB), detail: detail, warn: warn, closeTitle: tr("Close this page"))
    }

    func row(title: String, url: String, trailing: String, detail: String?, warn: Bool, closeTitle: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: warn ? "exclamationmark.triangle.fill" : "doc").foregroundStyle(warn ? .orange : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.isEmpty ? url : title).font(.callout).lineLimit(1)
                Text(ChromeInspector.site(url)).font(.caption2).foregroundStyle(.secondary).lineLimit(1).help(url)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(warn ? .orange : .secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            Text(trailing).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Button(model.closing == url ? tr("Closing…") : closeTitle) { confirming = Target(url: url, title: title) }
                .controlSize(.small).disabled(model.closing != nil || model.running)
        }
        .padding(embedded ? 12 : 8)
        .modifier(RowBackground(embedded: embedded, warn: warn))
    }

    func note(_ text: String, color: Color) -> some View {
        Text(text).font(.caption).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }

    func mb(_ v: Double) -> String { MemoryFormat.string(mebibytes: v) }
}

/// A page row: glass in the main window, a light tint in the stand-alone window.
private struct RowBackground: ViewModifier {
    let embedded: Bool
    let warn: Bool
    func body(content: Content) -> some View {
        if embedded {
            content.glass(radius: 12, highlighted: warn)
        } else {
            content.background(RoundedRectangle(cornerRadius: 8).fill((warn ? Color.orange : Color.secondary).opacity(0.07)))
        }
    }
}
