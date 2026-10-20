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

/// The browser page's four places: the three tab-workspace tasks and the memory check.
enum BrowserSection: Hashable {
    case task(TabWorkspaceTask)
    case diagnostics
}

struct ChromePagesView: View {
    @ObservedObject var model: ChromePagesModel
    /// Inside the main window: on its gradient, rows on glass, the list loads when shown.
    var embedded = false
    @State private var confirming: ClosePlan?
    @State private var search = ""
    @State private var onlyRecommended = false
    @State private var section: BrowserSection = {
        let args = CommandLine.arguments
        if args.contains("--offscreen"), let i = args.firstIndex(of: "--tabs-task"), i + 1 < args.count {
            if args[i + 1] == "diagnostics" { return .diagnostics }
            return .task(TabWorkspaceTask(rawValue: args[i + 1]) ?? .organize)
        }
        return .task(.organize)
    }()
    struct ClosePlan: Identifiable { let id = UUID(); let tabs: [ChromeInspector.Tab] }

    var taskBinding: Binding<TabWorkspaceTask> {
        Binding(get: { if case let .task(t) = section { return t } else { return .organize } }, set: { section = .task($0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: tr("Tab organizer"), subtitle: section == .diagnostics ? summary
                       : tr("Group tabs without closing them, or save links and close tabs you are not using.")) {
                EmptyView()
            } below: {
                ThermoTabs(selection: $section,
                           options: TabWorkspaceTask.allCases.map { (BrowserSection.task($0), $0.title) } + [(.diagnostics, tr("Memory diagnostics"))],
                           label: tr("Browser pages"))
            }
            .padding(.horizontal, Theme.pagePadding).padding(.top, Theme.pageTop).padding(.bottom, Theme.Space.l)
            if section == .diagnostics { diagnosticsBody }
            else { TabWorkspaceView(app: model.app, task: taskBinding) }
        }
    }

    var diagnosticsBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar.padding(.horizontal, Theme.pagePadding).padding(.bottom, Theme.Space.m)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    if model.running { progress }
                    if let d = model.diagnosis { content(d) } else if !model.running { progress }
                }
                .padding(.horizontal, Theme.pagePadding).padding(.bottom, Theme.Space.xl)
                .frame(maxWidth: Theme.pageWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            selectionFooter
        }
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

    /// Pages that can be ticked right now: identified, not stale, and among the ones shown.
    var selectablePages: [ChromeInspector.PageChoice] {
        model.busy || model.inventoryStale ? [] : visiblePages.filter { $0.tab.canSelect }
    }

    var selectionFooter: some View {
        ActionBar {
            SelectAllButton(available: selectablePages.count,
                            selected: selectablePages.filter { model.selected.contains($0.id) }.count,
                            selectAll: { model.selected.formUnion(selectablePages.map(\.id)) },
                            clear: { model.selected.subtract(selectablePages.map(\.id)) })
            Text(trCount(model.selectedPages.count, "%1$@ page selected", "%1$@ pages selected"))
                .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                .contentTransition(.numericText())
            Spacer()
            Button(tr("Clear selection")) { model.selected = [] }
                .buttonStyle(PillButtonStyle()).disabled(model.busy || model.selected.isEmpty)
            Button(model.closing ?? tr("Close selected pages")) {
                confirming = ClosePlan(tabs: model.selectedPages.map(\.tab))
            }
            .buttonStyle(PillButtonStyle(prominent: true, color: Theme.danger)).disabled(!model.canCloseSelected)
        }
    }

    /// What the check can do next, with the privacy note behind its (?).
    var toolbar: some View {
        HStack(spacing: Theme.Space.s) {
            if model.running {
                Button(tr("Stop")) { model.stop() }.buttonStyle(PillButtonStyle()).controlSize(.small)
            } else {
                Button { model.start() } label: { Label(tr("Refresh tabs"), systemImage: "arrow.clockwise") }
                    .buttonStyle(PillButtonStyle()).controlSize(.small).disabled(model.busy)
                if model.canMeasure {
                    Button(model.diagnosis?.mode == .devtools ? tr("Measure again") : tr("Measure memory")) { model.start(measure: true) }
                        .buttonStyle(PillButtonStyle()).controlSize(.small).disabled(model.busy)
                }
            }
            InfoButton(text: tr("Thermo reads page IDs, titles, addresses, memory and current-tab markers, never page content. Nothing closes without confirmation."))
            Spacer()
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
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            switch model.phase {
            case .measuring(let round, let done, let total):
                Text(tr("Measuring pages (%1$@/%2$@): %3$@ of %4$@", String(round), "2", String(done), String(total)))
                    .font(Theme.secondary.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                ProgressView(value: Double(done), total: Double(max(total, 1))).tint(Theme.accent)
            case .waiting(let left):
                Text(tr("Waiting %1$@ s to see which pages grow…", String(left)))
                    .font(Theme.secondary.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                ProgressView(value: 60 - Double(left), total: 60).tint(Theme.accent)
            case .listingTabs:
                SkeletonList(rows: 5)
            case nil:
                if model.stopped {
                    EmptyState(symbol: "pause.circle", title: tr("Check stopped. You can start again when ready."))
                    Button(tr("Check again")) { model.start() }.buttonStyle(PillButtonStyle()).frame(maxWidth: .infinity)
                } else {
                    SkeletonList(rows: 5)
                }
            }
            if model.measuring { Text(ChromeInspector.debuggingBarNote).font(Theme.caption).foregroundStyle(Theme.caution) }
        }
    }

    @ViewBuilder
    func content(_ d: ChromeInspector.Diagnosis) -> some View {
        if let failed = model.closeFailed { note(failed, color: Theme.danger) }
        if let review = model.closeReview {
            section(review.summary, review.detail) { EmptyView() }
        }
        if model.resultsStale {
            note(tr("Page figures are from before closing. Measure again for fresh per-page memory."), color: Theme.caution)
        }
        pageSelection
        if d.mode == .tabs && model.canMeasure && !model.measuring {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 16)).foregroundStyle(Theme.accent)
                Text(tr("Which page leaks or uses the most memory? Measure every page twice, a minute apart."))
                    .font(Theme.secondary).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                InfoButton(text: ChromeInspector.debuggingBarNote)
                Spacer(minLength: Theme.Space.s)
                Button(tr("Measure memory")) { model.start(measure: true) }.buttonStyle(PillButtonStyle(prominent: true)).controlSize(.small)
            }
            .padding(Theme.Space.m)
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.accent.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.accent.opacity(0.2)))
        }
        if let h = d.hiddenText { note(h, color: Theme.caution) }
        if let g = d.gap { note(g, color: Theme.textSecondary) }
        if let r = d.report {
            if r.invalidTimestamp != true, let skipped = r.comparisonSkipped, skipped > 0 {
                note(tr("%1$@ pages had no comparable earlier sample; their growth was not evaluated.", String(skipped)), color: Theme.caution)
            }
            if r.invalidTimestamp == true {
                note(tr("Browser measurement times are invalid. Growth comparisons are unavailable; check again."), color: Theme.caution)
            }
        }
        if let r = d.report, !r.workers.isEmpty {
            section(tr("Workers"), tr("Background scripts associated with a site; closing a tab may not stop all of them.")) {
                InspectorPanel {
                    ForEach(Array(r.workers.prefix(5).enumerated()), id: \.offset) { i, w in
                        if i > 0 { InspectorDivider(inset: Theme.Space.l) }
                        HStack {
                            Text(tr("%1$@ runs %2$@ workers", w.site, String(w.count))).font(Theme.body).foregroundStyle(Theme.textPrimary)
                            Spacer()
                            if w.heapMB >= 1 { Text(mb(w.heapMB)).font(Theme.figure(.row, weight: .medium)).foregroundStyle(Theme.textSecondary) }
                        }
                        .padding(.horizontal, Theme.Space.l).padding(.vertical, 10)
                    }
                }
            }
        }
        if let h = d.hint {
            VStack(alignment: .leading, spacing: 6) {
                note(h, color: Theme.textSecondary)
                if d.mode != .devtools && d.app == "Google Chrome" {
                    Button(tr("Copy install command")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ChromeInspector.chromeUseInstall, forType: .string)
                    }
                    .buttonStyle(PillButtonStyle()).controlSize(.small)
                }
            }
        }
    }

    func section<C: View>(_ title: String, _ caption: String?, @ViewBuilder _ rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.xs) {
                Text(title).font(Theme.sectionTitle).foregroundStyle(Theme.textSecondary).accessibilityAddTraits(.isHeader)
                if let caption { InfoButton(text: caption) }
            }
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
        let shown = visiblePages
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.m) {
                SelectAllButton(title: tr("Choose pages to close"), available: selectablePages.count,
                                selected: selectablePages.filter { model.selected.contains($0.id) }.count,
                                selectAll: { model.selected.formUnion(selectablePages.map(\.id)) },
                                clear: { model.selected.subtract(selectablePages.map(\.id)) })
                InfoButton(text: tr("Recommendations are candidates, not automatic closures. Current pages are excluded; unsaved input, pinned status and audio are not inspected."))
                Spacer()
                Button(tr("Select recommended (%1$@)", String(model.recommendedPages.count))) { model.selectRecommended() }
                    .buttonStyle(PillButtonStyle()).controlSize(.small)
                    .disabled(model.busy || model.recommendedPages.isEmpty)
            }
            HStack(spacing: Theme.Space.s) {
                SearchField(text: $search, prompt: tr("Search pages"))
                ThermoTabs(selection: $onlyRecommended, options: [(false, tr("All pages")), (true, tr("Recommended"))],
                           size: .small, label: tr("Pages"))
            }
            if !model.pages.isEmpty && !model.pages.contains(where: { $0.tab.canSelect }) {
                note(tr("Tab identities are unavailable. Check Thermo's Automation permission and refresh tabs. These rows stay read-only until individual tabs can be identified."), color: Theme.caution)
            }
            if shown.isEmpty {
                InspectorPanel { EmptyState(symbol: "magnifyingglass", title: tr("No matching pages.")) }
            } else {
                RowList(items: shown, inset: 48) { selectableRow($0) }
            }
        }
    }

    func selectableRow(_ choice: ChromeInspector.PageChoice) -> some View {
        let title = choice.tab.title.isEmpty ? choice.tab.url : choice.tab.title
        let on = model.selected.contains(choice.id)
        let locked = model.inventoryStale || !choice.tab.canSelect
        return HStack(alignment: .top, spacing: Theme.Space.m) {
            SelectToggle(selected: on, locked: locked, label: tr("Select page: %1$@", title)) {
                if on { model.selected.remove(choice.id) } else { model.selected.insert(choice.id) }
            }
            .disabled(model.busy)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if choice.tab.active == true { StatusTag(text: tr("Current page in its window")) }
                    if choice.recommended { StatusTag(text: tr("Recommended"), color: Theme.caution) }
                }
                Text([ChromeInspector.site(choice.tab.url), model.position(choice.tab)].compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1).help(choice.tab.url)
                if let growth = choice.measured?.growth, growth.seconds.isFinite, growth.seconds > 0 {
                    Text(tr("Growth: %1$@ MiB over %2$@ s", String(format: "%+.1f", growth.heapMB), String(format: "%.0f", growth.seconds)))
                        .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                }
                ForEach(choice.reasons, id: \.self) {
                    Text($0).font(Theme.caption).foregroundStyle(Theme.caution).fixedSize(horizontal: false, vertical: true)
                }
                if locked { Text(tr("Refresh tabs to enable selection.")).font(Theme.caption).foregroundStyle(Theme.textTertiary) }
                if let status = model.closeResults.first(where: { $0.id == choice.id })?.status, status != .closed {
                    Text(tr("Not closed: page changed, became active, or could not be reached. Review it before retrying."))
                        .font(Theme.caption).foregroundStyle(Theme.caution).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(choice.measured.map { mb($0.heapMB) } ?? tr("No matched reading"))
                .font(choice.measured == nil ? Theme.caption : Theme.figure(.row, weight: .medium))
                .foregroundStyle(choice.measured == nil ? Theme.textTertiary : Theme.textPrimary).fixedSize()
                .help(choice.measured == nil ? tr("No unique memory reading matches this tab; identical titles and addresses cannot be paired reliably.") : "")
        }
        .padding(.horizontal, Theme.Space.m).padding(.vertical, 10)
        .background(on ? Theme.accent.opacity(0.07) : .clear)
        .hoverHighlight()
        .animation(Theme.quick, value: on)
    }

    func note(_ text: String, color: Color) -> some View {
        Text(text).font(Theme.secondary).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }

    func mb(_ v: Double) -> String { MemoryFormat.string(mebibytes: v) }
}
