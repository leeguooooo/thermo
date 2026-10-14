import AppKit
import CleanKit
import SwiftUI
import ThermoL10n

/// "View pages" on a browser's row in the Overview: measures every page twice, a minute apart, and
/// lists the ones that grow, the biggest, duplicate tabs, busy workers and hidden automation pages,
/// each with what to do. Selected pages close only after a reviewed batch confirmation.
struct BrowserPageActions: Sendable {
    var tabs: @Sendable (String) -> [ChromeInspector.Tab]?
    var close: @Sendable ([ChromeInspector.Tab], String) -> [ChromeInspector.TabCloseResult]
    var reading: @Sendable (String) -> BrowserCloseReading
    var wait: @Sendable () async -> Void
    static var live: Self {
        .init(tabs: { ChromeInspector.tabs(app: $0) }, close: { ChromeInspector.closeTabs($0, app: $1) },
              reading: { BrowserCloseReading.sample(app: $0) }, wait: { try? await Task.sleep(nanoseconds: 5_000_000_000) })
    }
}

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
    @Published private(set) var tabsSnapshot: [ChromeInspector.Tab]?
    @Published var selected: Set<String> = []
    @Published private(set) var closeResults: [ChromeInspector.TabCloseResult] = []
    @Published private(set) var inventoryStale = false
    @Published private(set) var closeReview: BrowserCloseReview?
    private let actions: BrowserPageActions
    private var task: Task<Void, Never>?
    private var generation = UUID()
    @Published private(set) var stopped = false

    init(app: String, appMemoryKB: Int?, gpuKB: Int?, actions: BrowserPageActions = .live) {
        self.app = app; self.appMemoryKB = appMemoryKB; self.gpuKB = gpuKB
        self.actions = actions
        // Test bundles can start with saved samples without querying the user's live browser.
        if let samples = Bundle.main.object(forInfoDictionaryKey: "ThermoBrowserFixtureSamples") as? [String], samples.count == 2 {
            loadFixture(before: samples[0], after: samples[1])
        }
    }

    func loadFixture(before: String, after: String) {
        func read(_ path: String) -> ChromeInspector.Snapshot? {
            guard let data = FS.head(path, limit: 1_048_576) else { return nil }
            return try? JSONDecoder().decode(ChromeInspector.Snapshot.self, from: data)
        }
        guard let first = read(before), let last = read(after) else { return }
        let process = ProcessIdentity(pid: 42, uid: getuid(), started: Date(timeIntervalSince1970: 100), executable: "/fixture/browser")
        let tabs = last.rows.filter { $0.type == "page" && !$0.url.isEmpty }.enumerated().map { index, page in
            ChromeInspector.Tab(window: 1, index: index + 1, url: page.url, title: page.title,
                                browserID: "fixture-" + page.targetId, active: index == 0, browserProcess: process)
        }
        accept(ChromeInspector.diagnosis(ChromeInspector.diagnose(last, before: first), app: app,
                                        appMemoryKB: appMemoryKB, gpuKB: gpuKB), tabs: tabs)
    }

    var pages: [ChromeInspector.PageChoice] {
        let tabs = tabsSnapshot ?? diagnosis?.tabs ?? (diagnosis?.report?.pages.enumerated().map {
            ChromeInspector.Tab(window: 0, index: $0.offset + 1, url: $0.element.url, title: $0.element.title)
        } ?? [])
        return ChromeInspector.pageChoices(tabs: tabs, report: diagnosis?.report, stale: resultsStale)
    }
    func position(_ tab: ChromeInspector.Tab) -> String? {
        guard tab.window != 0, tab.index > 0 else { return nil }
        let tabs = tabsSnapshot ?? diagnosis?.tabs ?? []
        var windows: [Int] = []
        for item in tabs where !windows.contains(item.window) { windows.append(item.window) }
        guard let index = windows.firstIndex(of: tab.window) else { return nil }
        return tr("Window %1$@ · tab %2$@", String(index + 1), String(tab.index))
    }
    var selectedPages: [ChromeInspector.PageChoice] { pages.filter { selected.contains($0.id) && $0.tab.canSelect } }
    var recommendedPages: [ChromeInspector.PageChoice] { inventoryStale ? [] : pages.filter(\.recommended) }
    var busy: Bool { running || closing != nil }
    var canCloseSelected: Bool { !busy && !inventoryStale && !selectedPages.isEmpty }
    func selectRecommended() { guard !busy else { return }; selected.formUnion(recommendedPages.map(\.id)) }
    func accept(_ diagnosis: ChromeInspector.Diagnosis, tabs: [ChromeInspector.Tab]?) {
        self.diagnosis = diagnosis
        tabsSnapshot = tabs ?? diagnosis.tabs
        inventoryStale = false
        selected.formIntersection(pages.filter { $0.tab.canSelect }.map(\.id))
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
        let app = app, memory = appMemoryKB, gpu = gpuKB, model = self, actions = actions
        task = Task { [weak self] in
            async let tabs = Task.detached { actions.tabs(app) }.value
            let d = await ChromeInspector.diagnose(app: app, measure: measure, watch: measure ? watch : nil, appMemoryKB: memory, gpuKB: gpu) { phase in
                Task { @MainActor in
                    guard model.generation == generation, !model.stopped else { return }
                    model.phase = phase
                }
            }
            let listed = await tabs
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            self.generation = UUID()
            self.resultsStale = false
            self.accept(d, tabs: listed)
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

    /// The plan is captured by the confirmation sheet; changing the selection later cannot expand it.
    func close(_ plan: [ChromeInspector.Tab]) {
        guard !busy, !inventoryStale, !plan.isEmpty else { return }
        closing = tr("Closing selected pages…")
        closeFailed = nil; closeReview = nil; closeResults = []
        let actions = actions, app = app
        Task { [weak self] in
            let before = await Task.detached { actions.reading(app) }.value
            let result = await Task.detached { actions.close(plan, app) }.value
            guard let self else { return }
            self.closeResults = result
            self.resultsStale = self.resultsStale || (self.diagnosis?.report != nil && result.contains { $0.status == .closed })
            self.selected.subtract(result.filter { $0.status == .closed }.map(\.id))
            self.closing = tr("Checking the effect of the action…")
            await actions.wait()
            async let after = Task.detached { actions.reading(app) }.value
            async let remaining = Task.detached { actions.tabs(app) }.value
            let (reading, tabs) = await (after, remaining)
            self.closeReview = BrowserCloseReview(results: result, remaining: tabs, before: before, after: reading)
            self.inventoryStale = tabs == nil
            self.appMemoryKB = reading.browserMemoryKB
            self.gpuKB = nil
            if let tabs {
                self.tabsSnapshot = tabs
                self.selected.formIntersection(tabs.filter(\.canSelect).map(\.selectionID))
                self.diagnosis?.tabs = tabs
                self.diagnosis?.duplicates = ChromeInspector.duplicates(tabs)
            }
            self.diagnosis?.gap = nil
            self.closing = nil
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
    @State private var confirming: ClosePlan?
    @State private var search = ""
    @State private var onlyRecommended = false
    @State private var manageTabs = true
    struct ClosePlan: Identifiable { let id = UUID(); let tabs: [ChromeInspector.Tab] }

    var body: some View {
        VStack(spacing: 0) {
            Picker(tr("Browser pages"), selection: $manageTabs) {
                Text(tr("Tab organizer")).tag(true)
                Text(tr("Memory diagnostics")).tag(false)
            }.pickerStyle(.segmented).padding(.horizontal, 24).padding(.top, 24)
            if manageTabs { TabWorkspaceView(app: model.app) }
            else { diagnosticsBody }
        }
    }

    var diagnosticsBody: some View {
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
            selectionFooter
        }
        .background(embedded ? Color.clear : Color(nsColor: .windowBackgroundColor))
        .onAppear { if embedded && model.diagnosis == nil && !model.running { model.start() } }
        .onDisappear { if model.running { model.stop() } }
        .sheet(item: $confirming) { plan in
            ConfirmSheet(title: trCount(plan.tabs.count, "Close %1$@ selected page?", "Close %1$@ selected pages?"),
                         summary: tr("The selected tabs close in %1$@. Unsaved input may be lost. Check that you no longer need these pages.", model.app),
                         destructive: true, heading: tr("Selected pages"),
                         lines: plan.tabs.map { [model.position($0), $0.title.isEmpty ? $0.url : $0.title, $0.url].compactMap { $0 }.joined(separator: "\n") },
                         footnote: tr("Only the pages in this list are closed. Changed or newly active pages are skipped. Browser memory and system pressure are checked again after 5 seconds."),
                         confirmTitle: tr("Close and recheck"),
                         confirm: { confirming = nil; model.close(plan.tabs) }, cancel: { confirming = nil })
        }
    }

    var selectionFooter: some View {
        HStack(spacing: 12) {
            Text(trCount(model.selectedPages.count, "%1$@ page selected", "%1$@ pages selected")).font(.callout.monospacedDigit())
            Spacer()
            Button(tr("Clear selection")) { model.selected = [] }.disabled(model.busy || model.selected.isEmpty)
            Button(model.closing ?? tr("Close selected pages")) {
                confirming = ClosePlan(tabs: model.selectedPages.map(\.tab))
            }
            .buttonStyle(.borderedProminent).disabled(!model.canCloseSelected)
        }
        .padding(embedded ? 20 : 14)
        .background(Color.primary.opacity(0.04))
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if !embedded { Image(systemName: "rectangle.stack").font(.title2).foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(embedded ? tr("Browser pages") : tr("Which %1$@ page is the problem", model.app))
                        .font(embedded ? .system(size: 26, weight: .bold) : .headline)
                    Text(summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                if model.running {
                    Button(tr("Stop")) { model.stop() }.controlSize(.small)
                } else {
                    Button(tr("Refresh tabs")) { model.start() }.controlSize(.small).disabled(model.busy)
                    if model.canMeasure {
                        Button(model.diagnosis?.mode == .devtools ? tr("Measure again") : tr("Measure memory")) { model.start(measure: true) }
                            .controlSize(.small).buttonStyle(.borderedProminent).disabled(model.busy)
                    }
                }
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
            return (model.tabsSnapshot.map { tr("%1$@ tabs", String($0.count)) + " · " } ?? "") + tr("%1$@ measured pages, %2$@ workers · JavaScript %3$@", String(r.pages.count), String(r.workerCount), mb(r.pagesHeapMB + r.workersHeapMB))
                + (r.unmeasured > 0 ? " · " + ChromeInspector.unmeasuredText(r.unmeasured) : "")
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
            Text(tr("Thermo reads page IDs, titles, addresses, memory and current-tab markers, never page content. Nothing closes without confirmation."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    func content(_ d: ChromeInspector.Diagnosis) -> some View {
        if let failed = model.closeFailed { note(failed, color: .red) }
        if let review = model.closeReview {
            section(review.summary, review.detail) { EmptyView() }
        }
        if model.resultsStale {
            note(tr("Page figures are from before closing. Measure again for fresh per-page memory."), color: .orange)
        }
        pageSelection
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
            if r.invalidTimestamp != true, let skipped = r.comparisonSkipped, skipped > 0 {
                note(tr("%1$@ pages had no comparable earlier sample; their growth was not evaluated.", String(skipped)), color: .orange)
            }
            if r.invalidTimestamp == true {
                note(tr("Browser measurement times are invalid. Growth comparisons are unavailable; check again."), color: .orange)
            }
        }
        if let r = d.report, !r.workers.isEmpty {
            section(tr("Workers"), tr("Background scripts associated with a site; closing a tab may not stop all of them.")) {
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

    var visiblePages: [ChromeInspector.PageChoice] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.pages.filter { page in
            (!onlyRecommended || page.recommended) && (query.isEmpty || (page.tab.title + " " + page.tab.url).localizedCaseInsensitiveContains(query))
        }
    }

    var pageSelection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("Choose pages to close")).font(.subheadline.weight(.semibold))
            Text(tr("Recommendations are candidates, not automatic closures. Current pages are excluded; unsaved input, pinned status and audio are not inspected."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) { selectionTools; Spacer(minLength: 0) }
                .fixedSize(horizontal: false, vertical: true)
            TextField(tr("Search pages"), text: $search).textFieldStyle(.roundedBorder).accessibilityLabel(tr("Search pages"))
            if !model.pages.isEmpty && !model.pages.contains(where: { $0.tab.canSelect }) {
                note(tr("Tab identities are unavailable. Check Thermo's Automation permission and refresh tabs. These rows stay read-only until individual tabs can be identified."), color: .orange)
            }
            ForEach(visiblePages) { choice in selectableRow(choice) }
            if visiblePages.isEmpty { note(tr("No matching pages."), color: .secondary) }
        }
    }
    @ViewBuilder var selectionTools: some View {
        Picker(tr("Pages"), selection: $onlyRecommended) {
            Text(tr("All pages")).tag(false)
            Text(tr("Recommended")).tag(true)
        }.pickerStyle(.segmented).labelsHidden().frame(width: 230)
        Button(tr("Select recommended (%1$@)", String(model.recommendedPages.count))) { model.selectRecommended() }
            .disabled(model.busy || model.recommendedPages.isEmpty)
    }
    func selectableRow(_ choice: ChromeInspector.PageChoice) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(isOn: Binding(get: { model.selected.contains(choice.id) }, set: { on in
                if on { model.selected.insert(choice.id) } else { model.selected.remove(choice.id) }
            })) { Text(choice.tab.title.isEmpty ? choice.tab.url : choice.tab.title) }
            .toggleStyle(.checkbox).labelsHidden()
            .accessibilityLabel(tr("Select page: %1$@", choice.tab.title.isEmpty ? choice.tab.url : choice.tab.title))
            .disabled(model.busy || model.inventoryStale || !choice.tab.canSelect)
            VStack(alignment: .leading, spacing: 3) {
                Text(choice.tab.title.isEmpty ? choice.tab.url : choice.tab.title).font(.callout).lineLimit(2)
                Text([ChromeInspector.site(choice.tab.url), model.position(choice.tab)].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(choice.tab.url)
                if choice.tab.active == true { Text(tr("Current page in its window")).font(.caption2).foregroundStyle(.secondary) }
                if let growth = choice.measured?.growth, growth.seconds.isFinite, growth.seconds > 0 {
                    Text(tr("Growth: %1$@ MiB over %2$@ s", String(format: "%+.1f", growth.heapMB), String(format: "%.0f", growth.seconds)))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                ForEach(choice.reasons, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                if model.inventoryStale || !choice.tab.canSelect { Text(tr("Refresh tabs to enable selection.")).font(.caption).foregroundStyle(.secondary) }
                if let status = model.closeResults.first(where: { $0.id == choice.id })?.status, status != .closed {
                    Text(tr("Not closed: page changed, became active, or could not be reached. Review it before retrying."))
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(choice.measured.map { mb($0.heapMB) } ?? tr("No matched reading"))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
                .help(choice.measured == nil ? tr("No unique memory reading matches this tab; identical titles and addresses cannot be paired reliably.") : "")
        }
        .padding(embedded ? 12 : 8)
        .modifier(RowBackground(embedded: embedded, warn: choice.recommended))
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
