import AppKit
import CleanKit
import SwiftUI
import ThermoL10n
import UserNotifications

/// Scans only when the user starts it (low priority, stoppable at any time), notifies
/// when a scan finishes in the background, and removes what the user ticks.
final class DiskModel: ObservableObject {
    enum Scope: String, CaseIterable, Identifiable, Sendable {
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
    @Published private(set) var sessionRetentionDays: Int?
    /// Everything by default: build output in every project is often the biggest win.
    @Published var scope: Scope = .all {
        didSet {
            if scope != oldValue {
                invalidateSavedLoad()
                if report != nil { stale = true }
            }
        }
    }
    /// The scope changed since the results were found; scan again to refresh.
    @Published private(set) var stale = false
    @Published private(set) var resultsNeedRefresh = false
    /// The scan in progress, so it can be stopped.
    private var scanCancellation: ScanCancellation?
    @Published private(set) var loadingSaved = false
    private let scanIO: DiskScanIO
    private let requestNotifications: () -> Void
    private var savedLoadGeneration = UUID()
    private var savedReadRunning = false
    private var savedRequest: SavedRequest?
    private struct SavedRequest: Equatable {
        var scope: Scope
        var category: CleanCategory?
        var retention: Int?
        var language: String
        var scanIfMissing: Bool
        func matches(_ other: SavedRequest) -> Bool {
            scope == other.scope && category == other.category && retention == other.retention && language == other.language
        }
    }
    @Published private(set) var stopping = false
    @Published private(set) var protectionNotice: String?
    @Published private(set) var protectionUndo: Whitelist.AdditionUndo?
    @Published var lastResult: String?
    @Published var error: String?
    /// While cleaning: which item is being removed, and how far along we are.
    @Published private(set) var cleaningStep = ""
    @Published private(set) var cleaningDone = 0
    @Published private(set) var cleaningTotal = 0

    init(report: ScanReport? = nil, scanIO: DiskScanIO = .live, requestNotifications: @escaping () -> Void = Monitor.requestNotificationPermission) {
        self.report = report
        self.scanIO = scanIO
        self.requestNotifications = requestNotifications
    }

    private let queue = DispatchQueue(label: "dev.thermo.app.disk", qos: .background)

    /// What a clean would remove: ticked items, narrowed to the parts still ticked.
    var selectedItems: [CleanItem] {
        // An unreadable whitelist disables cleaning altogether.
        guard report?.whitelistError == nil else { return [] }
        return (report?.items ?? []).filter {
            selected.contains($0.id) && $0.cleanable && ($0.category != .aiSessions ||
                (sessionRetentionDays != nil && report?.sessionPolicyVersion == ScanOptions.sessionPolicyVersion && report?.sessionRetentionDays == sessionRetentionDays))
        }.compactMap { i in
            guard let off = excluded[i.id], !off.isEmpty, let parts = i.parts else { return i }
            let narrowed = i.only(Set(parts.map(\.id)).subtracting(off))
            return narrowed.bytes > 0 ? narrowed : nil
        }
    }
    var languageStale: Bool { report.map { $0.language != L10n.current.rawValue } ?? false }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }

    func setSessionRetentionDays(_ days: Int?) {
        guard !scanning, !cleaning, days != sessionRetentionDays, days.map({ $0 >= 0 }) ?? true else { return }
        invalidateSavedLoad()
        sessionRetentionDays = days
        report = nil; selected = []; excluded = [:]
        stale = false; resultsNeedRefresh = false; lastResult = nil; error = nil
    }

    func scopeNeedsRefresh(category: CleanCategory? = nil) -> Bool {
        guard !scanning, let report else { return false }
        if let category {
            if category == .aiSessions, report.sessionPolicyVersion != ScanOptions.sessionPolicyVersion || report.sessionRetentionDays != sessionRetentionDays { return true }
            return !(report.categories ?? []).contains(category)
        }
        return stale
    }

    static let order = Dictionary(uniqueKeysWithValues: CleanCategory.allCases.enumerated().map { ($1, $0) })

    static func sorted(_ items: [CleanItem]) -> [CleanItem] {
        items.sorted { (order[$0.category]!, -$0.bytes, $0.id) < (order[$1.category]!, -$1.bytes, $1.id) }
    }

    /// Repeated page appearances share one physical reader. A later request replaces
    /// the pending scope; superseded results never become a cleanup plan.
    func loadSaved(category: CleanCategory? = nil, scanIfMissing: Bool = false) {
        guard report == nil, !scanning, !cleaning else { return }
        let request = SavedRequest(scope: scope, category: category, retention: sessionRetentionDays,
                                   language: L10n.current.rawValue, scanIfMissing: scanIfMissing)
        if let current = savedRequest, current.matches(request) {
            savedRequest?.scanIfMissing = current.scanIfMissing || scanIfMissing
            return
        }
        savedRequest = request
        savedLoadGeneration = UUID()
        loadingSaved = true
        if !savedReadRunning { readSaved() }
    }

    private func invalidateSavedLoad() {
        savedLoadGeneration = UUID()
        savedRequest = nil
        loadingSaved = false
    }

    private func readSaved() {
        guard let request = savedRequest else { return }
        let generation = savedLoadGeneration, io = scanIO
        savedReadRunning = true
        queue.async { [weak self] in
            let options = io.options(request.scope, request.category, request.retention)
            let cached = io.cached(options, request.language)
            DispatchQueue.main.async {
                guard let self else { return }
                self.savedReadRunning = false
                guard generation == self.savedLoadGeneration else {
                    if self.savedRequest != nil { self.readSaved() }
                    return
                }
                let autoScan = self.savedRequest?.scanIfMissing == true
                self.savedRequest = nil
                self.loadingSaved = false
                guard self.report == nil, !self.scanning, !self.cleaning,
                      self.scope == request.scope, self.sessionRetentionDays == request.retention,
                      L10n.current.rawValue == request.language else { return }
                if let cached {
                    self.report = cached
                    self.selected = Set(cached.items.filter(\.automaticallySelected).map(\.id))
                } else if autoScan { self.scan(category: request.category) }
            }
        }
    }

    static func scanOptions(scope: Scope, category: CleanCategory? = nil, sessionRetentionDays: Int? = nil) -> ScanOptions {
        var options = ScanOptions()
        options.sessionRetentionDays = category == .aiSessions || (category == nil && scope == .ai) ? sessionRetentionDays : nil
        options.lowPriority = true
        if let category { options.categories = [category] }
        else if scope == .ai { options.categories = Set(CleanCategory.allCases.filter(\.isAI)) }
        return options
    }

    func scan(category: CleanCategory? = nil) {
        guard !scanning, !cleaning else { return }
        requestNotifications()
        scanning = true
        stopping = false
        stale = false
        resultsNeedRefresh = false
        error = nil
        lastResult = nil
        protectionNotice = nil; protectionUndo = nil
        progress = tr("starting…")
        report = nil
        selected = []
        excluded = [:]
        invalidateSavedLoad()
        let cancellation = ScanCancellation()
        scanCancellation = cancellation
        let requestedScope = scope, retention = sessionRetentionDays, io = scanIO
        let started = Date(), language = L10n.current.rawValue
        let stoppedReport: @Sendable () -> ScanReport = {
            var report = ScanReport(items: [], denied: [], started: started, duration: Date().timeIntervalSince(started), cancelled: true)
            report.language = language
            report.categories = category.map { [$0] } ?? CleanCategory.allCases.filter { requestedScope == .all || $0.isAI }
            report.sessionRetentionDays = category == .aiSessions || (category == nil && requestedScope == .ai) ? retention : nil
            report.sessionPolicyVersion = ScanOptions.sessionPolicyVersion
            return report
        }
        queue.async { [weak self] in
            let result: ScanReport
            if cancellation.isCancelled { result = stoppedReport() }
            else {
                let options = io.options(requestedScope, category, retention)
                if cancellation.isCancelled { result = stoppedReport() }
                else {
                    result = io.scan(options, cancellation, { step in
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.scanning, self.scanCancellation === cancellation else { return }
                            self.progress = step
                        }
                    }, { found in
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.scanning, self.scanCancellation === cancellation else { return }
                            let items = Self.sorted((self.report?.items ?? []) + found)
                            self.report = ScanReport(items: items, denied: [], started: started, duration: Date().timeIntervalSince(started))
                            self.report?.language = language
                            self.report?.sessionRetentionDays = options.sessionRetentionDays
                            self.report?.sessionPolicyVersion = ScanOptions.sessionPolicyVersion
                            self.selected.formUnion(found.filter(\.automaticallySelected).map(\.id))
                        }
                    })
                }
            }
            DispatchQueue.main.async {
                guard let self, self.scanCancellation === cancellation else { return }
                self.acceptScan(result)
                self.scanning = false
                self.stopping = false
                self.scanCancellation = nil
                if !result.cancelled { self.notifyFinished(result) }
            }
        }
    }

    /// Preserve choices made while partial results were arriving. Only newly discovered safe items are selected.
    func acceptScan(_ result: ScanReport) {
        invalidateSavedLoad()
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
        guard scanning, let scanCancellation else { return }
        stopping = true
        progress = tr("stopping…")
        scanCancellation.cancel()
    }

    /// Tell the user a scan finished, unless they are looking at it.
    private func notifyFinished(_ r: ScanReport) {
        guard r.duration > 3, let app = NSApp, Bundle.main.bundleIdentifier != nil else { return }
        let watching = app.isActive && (app.keyWindow?.isVisible ?? false)
        guard !watching else { return }
        let content = UNMutableNotificationContent()
        content.title = tr("Disk scan finished")
        content.body = r.items.isEmpty ? tr("Nothing to clean.")
            : tr("%1$@ reclaimable in %2$@", ByteFormat.string(r.totalBytes), trCount(r.items.count, "%1$@ item", "%1$@ items"))
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "thermo.disk-scan", content: content, trigger: nil))
    }

    func clean(review: DiskCleanupReview? = nil) {
        guard !cleaning, !scanning else { return }
        if let review, !isCurrentCleanupReview(review) {
            error = tr("Cleanup plan changed. Review the current items before cleaning.")
            lastResult = nil
            return
        }
        let items = review?.items ?? selectedItems
        let scannedAt = review == nil ? report?.started : review?.scannedAt
        let originals = Dictionary(uniqueKeysWithValues: (report?.items ?? []).map { ($0.id, $0) })
        guard !items.isEmpty, !cleaning, !scanning else { return }
        error = nil; lastResult = nil
        invalidateSavedLoad()
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
            var text = estimateIncomplete
                ? (freed == 0 ? tr("Removed size is unknown") : tr("Measured removed size: %1$@; total size is unknown", ByteFormat.string(freed)))
                : tr("deleted %1$@ (estimated file size)", ByteFormat.string(freed))
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
    func alwaysKeep(_ item: CleanItem, paths: [String]? = nil, home: String = NSHomeDirectory()) {
        guard !cleaning, !scanning else { return }
        do {
            let change = try Whitelist.addWithUndo(paths ?? (item.paths + (item.commandScope ?? [])), home: home)
            invalidateSavedLoad()
            protectionUndo = change.undo
            protectionNotice = change.added.isEmpty ? tr("These locations are already protected.") : tr("Protected %1$@ locations from cleanup.", String(change.added.count))
            error = nil
        } catch {
            self.error = error.localizedDescription
            return
        }
        report?.applyWhitelist(home: home)
        let cleanable = Set((report?.items ?? []).filter(\.cleanable).map(\.id))
        selected = selected.intersection(cleanable)
        if let parts = report?.items.first(where: { $0.id == item.id })?.parts, var off = excluded[item.id] {
            off.formIntersection(parts.map(\.id))
            excluded[item.id] = off.isEmpty ? nil : off
        }
    }

    func undoProtection() {
        guard !cleaning, !scanning, let undo = protectionUndo else { return }
        do {
            try Whitelist.undoAddition(undo)
            protectionUndo = nil
            protectionNotice = tr("Protection undone. Scan again to review the available cleanup items.")
            // Protection filtering may have narrowed paths and sizes. Never reconstruct an old deletion plan.
            invalidateSavedLoad()
            report = nil; selected = []; excluded = [:]; error = nil
        } catch { self.error = error.localizedDescription }
    }

    func protectionRulesChanged() {
        invalidateSavedLoad()
        protectionUndo = nil
        protectionNotice = tr("Protection changed. Scan again to review the available cleanup items.")
        report = nil; selected = []; excluded = [:]; error = nil
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
