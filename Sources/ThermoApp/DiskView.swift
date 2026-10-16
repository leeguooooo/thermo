import AppKit
import CleanKit
import SwiftUI
import ThermoL10n
import UserNotifications

/// Scans only when the user starts it (low priority, stoppable at any time), notifies
/// when a scan finishes in the background, and removes what the user ticks.
final class DiskModel: ObservableObject {
    enum Scope: String, CaseIterable, Identifiable {
        case ai = "AI", all = "Everything"
        var id: String { rawValue }
        var label: String { self == .ai ? "AI" : tr("Everything") }
    }

    @Published private(set) var report: ScanReport?
    @Published private(set) var scanning = false
    @Published private(set) var cleaning = false
    @Published private(set) var progress = ""
    @Published var selected: Set<String> = []
    /// Item id → parts (sessions) the user unticked inside a selected item.
    @Published var excluded: [String: Set<String>] = [:]
    /// Everything by default: build output in every project is often the biggest win.
    @Published var scope: Scope = .all {
        didSet { if scope != oldValue, report != nil { stale = true } }
    }
    /// The scope changed since the results were found; scan again to refresh.
    @Published private(set) var stale = false
    @Published private(set) var resultsNeedRefresh = false
    /// The scan in progress, so it can be stopped.
    private var scanner: DiskScanner?
    @Published private(set) var stopping = false
    @Published var lastResult: String?
    @Published var error: String?
    /// While cleaning: which item is being removed, and how far along we are.
    @Published private(set) var cleaningStep = ""
    @Published private(set) var cleaningDone = 0
    @Published private(set) var cleaningTotal = 0

    init(report: ScanReport? = nil) { self.report = report }

    private let queue = DispatchQueue(label: "dev.thermo.app.disk", qos: .background)

    /// What a clean would remove: ticked items, narrowed to the parts still ticked.
    var selectedItems: [CleanItem] {
        // An unreadable whitelist disables cleaning altogether.
        guard report?.whitelistError == nil else { return [] }
        return (report?.items ?? []).filter { selected.contains($0.id) && $0.cleanable }.compactMap { i in
            guard let off = excluded[i.id], !off.isEmpty, let parts = i.parts else { return i }
            let narrowed = i.only(Set(parts.map(\.id)).subtracting(off))
            return narrowed.bytes > 0 ? narrowed : nil
        }
    }
    var languageStale: Bool { report.map { $0.language != L10n.current.rawValue } ?? false }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }

    func scopeNeedsRefresh(category: CleanCategory? = nil) -> Bool {
        guard !scanning, let report else { return false }
        if let category { return !(report.categories ?? []).contains(category) }
        return stale
    }

    static let order = Dictionary(uniqueKeysWithValues: CleanCategory.allCases.enumerated().map { ($1, $0) })

    static func sorted(_ items: [CleanItem]) -> [CleanItem] {
        items.sorted { (order[$0.category]!, -$0.bytes, $0.id) < (order[$1.category]!, -$1.bytes, $1.id) }
    }

    /// Shows the last finished scan (CLI or app) when it is under an hour old and covers the
    /// current scope, so the window opens with results instead of minutes of scanning.
    @discardableResult
    func loadSaved(category: CleanCategory? = nil) -> Bool {
        // The CLI scans in English; a report in another language would show the wrong titles here.
        let wanted = category.map { Set([$0]) } ?? (scope == .ai ? Set(CleanCategory.allCases.filter(\.isAI)) : Set(CleanCategory.allCases))
        let options = Self.scanOptions(scope: scope, category: category)
        guard report == nil, !scanning, let r = ScanReportCache.load(maxAge: 3600, matching: {
            $0.language == L10n.current.rawValue && wanted.isSubset(of: Set($0.categories ?? [])) &&
                $0.projectRoots == Array(Set(options.projectRoots)).sorted() &&
                $0.discoverProjectRoots == options.discoverProjectRoots && $0.olderThanDays == options.olderThanDays
        }) else { return false }
        var marked = r
        marked.applyWhitelist()
        report = marked
        selected = Set(r.items.filter(\.automaticallySelected).map(\.id))
        return true
    }

    static func scanOptions(scope: Scope, category: CleanCategory? = nil) -> ScanOptions {
        var options = ScanOptions()
        options.lowPriority = true
        if let category { options.categories = [category] }
        else if scope == .ai { options.categories = Set(CleanCategory.allCases.filter(\.isAI)) }
        return options
    }

    func scan(category: CleanCategory? = nil) {
        guard !scanning, !cleaning else { return }
        Monitor.requestNotificationPermission()
        scanning = true
        stopping = false
        stale = false
        resultsNeedRefresh = false
        error = nil
        lastResult = nil
        progress = tr("starting…")
        report = nil
        selected = []
        excluded = [:]
        let options = Self.scanOptions(scope: scope, category: category)
        let scanner = DiskScanner(options: options)
        self.scanner = scanner
        let started = Date()
        let language = L10n.current.rawValue
        scanner.onProgress = { [weak self] step in DispatchQueue.main.async { self?.progress = step } }
        // Results show up as each step finishes; safe ones are ticked as they arrive.
        scanner.onItems = { [weak self] found in
            DispatchQueue.main.async {
                guard let self, self.scanning else { return }
                let items = Self.sorted((self.report?.items ?? []) + found)
                self.report = ScanReport(items: items, denied: [], started: started, duration: Date().timeIntervalSince(started))
                self.report?.language = language
                self.selected.formUnion(found.filter(\.automaticallySelected).map(\.id))
            }
        }
        queue.async { [weak self] in
            let r = scanner.scan()
            DispatchQueue.main.async {
                guard let self else { return }
                self.acceptScan(r)
                self.scanning = false
                self.stopping = false
                self.scanner = nil
                if !r.cancelled { self.notifyFinished(r) }
            }
        }
    }

    /// Preserve choices made while partial results were arriving. Only newly discovered safe items are selected.
    func acceptScan(_ result: ScanReport) {
        let seen = Set(report?.items.map(\.id) ?? [])
        let newSafe = result.items.filter { !seen.contains($0.id) && $0.automaticallySelected }
        selected = selected.intersection(result.items.filter(\.cleanable).map(\.id)).union(newSafe.map(\.id))
        report = result
        if let categories = result.categories {
            let expected = scope == .ai ? CleanCategory.allCases.filter(\.isAI) : CleanCategory.allCases
            stale = Set(categories) != Set(expected)
        }
    }

    /// Stop the running scan; whatever was found so far stays on screen.
    func stop() {
        guard scanning, let scanner else { return }
        stopping = true
        progress = tr("stopping…")
        scanner.cancel()
    }

    /// Tell the user a scan finished, unless they are looking at it.
    private func notifyFinished(_ r: ScanReport) {
        let watching = NSApp.isActive && (NSApp.keyWindow?.isVisible ?? false)
        guard !watching, r.duration > 3, Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = tr("Disk scan finished")
        content.body = r.items.isEmpty ? tr("Nothing to clean.")
            : tr("%1$@ reclaimable in %2$@", ByteFormat.string(r.totalBytes), trCount(r.items.count, "%1$@ item", "%1$@ items"))
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "thermo.disk-scan", content: content, trigger: nil))
    }

    func clean() {
        let items = selectedItems
        let scannedAt = report?.started
        let originals = Dictionary(uniqueKeysWithValues: (report?.items ?? []).map { ($0.id, $0) })
        guard !items.isEmpty, !cleaning, !scanning else { return }
        cleaning = true
        cleaningDone = 0
        cleaningTotal = items.count
        queue.async { [weak self] in
            do { _ = try Whitelist.loadForRemoval() } catch {
                let why = Whitelist.unreadable(error)
                DispatchQueue.main.async { self?.error = why; self?.cleaning = false }
                return
            }
            ScanReportCache.invalidate()
            let spaceBefore = DiskSpaceSnapshot.measure()
            let batchID = UUID().uuidString
            var batchRecorded = false
            var partialCount = 0
            var estimateIncomplete = false
            var removedAny = false
            var freed: Int64 = 0, trashed: Int64 = 0, failures = 0, kept = 0
            var remaining: [String: CleanItem] = [:]
            for (n, i) in items.enumerated() {
                DispatchQueue.main.async { self?.cleaningStep = i.title; self?.cleaningDone = n }
                let r = Cleaner.clean(i, scannedAt: scannedAt, batchID: batchID)
                batchRecorded = batchRecorded || r.trashBatchID == batchID
                partialCount += r.outcome == "partial" ? 1 : 0
                estimateIncomplete = estimateIncomplete || r.bytesIncomplete == true
                removedAny = removedAny || !r.removed.isEmpty || r.partialRemoved?.isEmpty == false || r.partialCommands?.isEmpty == false || (r.bytesIncomplete == true && !(i.commands ?? []).isEmpty)
                if r.trashed { trashed += r.trashedAllocatedBytes ?? r.bytes } else { freed += r.bytes }
                failures += r.failed.count
                kept += r.whitelisted?.count ?? 0
                if let original = originals[i.id], let rest = Self.remainder(original, attempted: i, result: r) {
                    remaining[i.id] = rest
                }
            }
            let observation = DiskSpaceObservation(before: spaceBefore, after: DiskSpaceSnapshot.measure())
            var text = tr("deleted %1$@ (estimated file size)", ByteFormat.string(freed))
            if trashed > 0 { text += tr(", %1$@ still occupies Trash space; empty only this batch to reclaim it", ByteFormat.string(trashed)) }
            if batchRecorded { text += "\nthermo clean empty-trash \(batchID) --dry-run" }
            if partialCount > 0 { text += " · " + tr("%1$@ items partially completed; remaining files kept", String(partialCount)) }
            if estimateIncomplete { text += " · " + tr("Removed size could not be measured completely") }
            if failures > 0 { text += " · " + trCount(failures, "%1$@ path could not be removed (see log)", "%1$@ paths could not be removed (see log)") }
            if kept > 0 { text += " · " + tr("%1$@ whitelisted paths kept", String(kept)) }
            text += "\n" + observation.summary
            let invalidateOverview = removedAny
            let remainingItems = remaining
            let hadFailures = failures > 0
            DispatchQueue.main.async {
                guard let self else { return }
                if invalidateOverview { SpaceOverviewModel.shared.invalidateAfterCleanup() }
                self.cleaning = false
                self.cleaningDone = self.cleaningTotal
                self.resultsNeedRefresh = hadFailures
                self.cleaningStep = ""
                self.lastResult = text
                // Drop what was cleaned instead of rescanning the whole disk.
                let cleaned = Set(items.map(\.id))
                if var r = self.report {
                    r.items = r.items.compactMap { cleaned.contains($0.id) ? remainingItems[$0.id] : $0 }
                    self.report = r
                }
                self.selected.subtract(cleaned)
                for id in cleaned { self.excluded[id] = nil }
            }
        }
    }

    func toggle(_ item: CleanItem) {
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id); excluded[item.id] = nil }
    }

    func isTicked(_ part: CleanPart, of item: CleanItem) -> Bool {
        selected.contains(item.id) && !(excluded[item.id]?.contains(part.id) ?? false)
    }

    /// Ticking a session ticks its item; unticking the last one unticks the item.
    func toggle(_ part: CleanPart, of item: CleanItem) {
        if isTicked(part, of: item) {
            excluded[item.id, default: []].insert(part.id)
            if excluded[item.id]!.count >= (item.parts?.count ?? 0) { selected.remove(item.id); excluded[item.id] = nil }
        } else if !selected.contains(item.id) {
            // First tick inside an unticked item: only this session.
            selected.insert(item.id)
            excluded[item.id] = Set((item.parts ?? []).map(\.id)).subtracting([part.id])
        } else {
            excluded[item.id]?.remove(part.id)
        }
    }

    /// "Always keep": the item's paths (or just some: one session, one path) go into the whitelist
    /// and stay out of every cleanup.
    func alwaysKeep(_ item: CleanItem, paths: [String]? = nil) {
        do {
            try Whitelist.add(paths ?? item.paths)
            error = nil
        } catch {
            self.error = error.localizedDescription
            return
        }
        report?.applyWhitelist()
        let cleanable = Set((report?.items ?? []).filter(\.cleanable).map(\.id))
        selected = selected.intersection(cleanable)
        if let parts = report?.items.first(where: { $0.id == item.id })?.parts, var off = excluded[item.id] {
            off.formIntersection(parts.map(\.id))
            excluded[item.id] = off.isEmpty ? nil : off
        }
    }

    func openFullDiskAccess() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    func reveal(_ item: CleanItem) {
        let urls = item.paths.prefix(20).map { URL(fileURLWithPath: $0) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(Array(urls)) }
    }

    func openLog() { NSWorkspace.shared.open(Cleaner.logURL) }
}

struct SafetyTag: View {
    let safety: Safety
    var info = false
    var body: some View {
        let (text, color): (String, Color) = info ? (tr("info"), .blue)
            : safety == .safe ? (tr("safe"), .green) : safety == .review ? (tr("review"), .orange) : (tr("risky"), .red)
        // Same capsule as AgentTag, tinted by safety.
        Text(text).font(.caption2.weight(.medium)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}
