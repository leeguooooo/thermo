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
    @Published var scope: Scope = .ai {
        didSet { if scope != oldValue, report != nil { stale = true } }
    }
    /// The scope changed since the results were found; scan again to refresh.
    @Published private(set) var stale = false
    /// The scan in progress, so it can be stopped.
    private var scanner: DiskScanner?
    @Published private(set) var stopping = false
    @Published var lastResult: String?
    @Published var error: String?
    /// While cleaning: which item is being removed, and how far along we are.
    @Published private(set) var cleaningStep = ""
    @Published private(set) var cleaningDone = 0
    @Published private(set) var cleaningTotal = 0

    private let queue = DispatchQueue(label: "dev.thermo.app.disk", qos: .background)

    /// What a clean would remove: ticked items, narrowed to the parts still ticked.
    var selectedItems: [CleanItem] {
        (report?.items ?? []).filter { selected.contains($0.id) && $0.cleanable }.compactMap { i in
            guard let off = excluded[i.id], !off.isEmpty, let parts = i.parts else { return i }
            let narrowed = i.only(Set(parts.map(\.id)).subtracting(off))
            return narrowed.bytes > 0 ? narrowed : nil
        }
    }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }

    static let order = Dictionary(uniqueKeysWithValues: CleanCategory.allCases.enumerated().map { ($1, $0) })

    static func sorted(_ items: [CleanItem]) -> [CleanItem] {
        items.sorted { (order[$0.category]!, -$0.bytes, $0.id) < (order[$1.category]!, -$1.bytes, $1.id) }
    }

    func scan() {
        guard !scanning else { return }
        Monitor.requestNotificationPermission()
        scanning = true
        stopping = false
        stale = false
        progress = tr("starting…")
        report = nil
        selected = []
        excluded = [:]
        var options = ScanOptions()
        options.lowPriority = true
        if scope == .ai { options.categories = Set(CleanCategory.allCases.filter(\.isAI)) }
        let scanner = DiskScanner(options: options)
        self.scanner = scanner
        let started = Date()
        scanner.onProgress = { [weak self] step in DispatchQueue.main.async { self?.progress = step } }
        // Results show up as each step finishes; safe ones are ticked as they arrive.
        scanner.onItems = { [weak self] found in
            DispatchQueue.main.async {
                guard let self, self.scanning else { return }
                let items = Self.sorted((self.report?.items ?? []) + found)
                self.report = ScanReport(items: items, denied: [], started: started, duration: Date().timeIntervalSince(started))
                self.selected.formUnion(found.filter { $0.cleanable && $0.safety == .safe }.map(\.id))
            }
        }
        queue.async { [weak self] in
            let r = scanner.scan()
            DispatchQueue.main.async {
                guard let self else { return }
                self.report = r
                self.selected = self.selected.intersection(r.items.map(\.id))
                    .union(r.items.filter { $0.cleanable && $0.safety == .safe }.map(\.id))
                self.scanning = false
                self.stopping = false
                self.scanner = nil
                if !r.cancelled { self.notifyFinished(r) }
            }
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
        guard !items.isEmpty, !cleaning else { return }
        cleaning = true
        cleaningDone = 0
        cleaningTotal = items.count
        queue.async { [weak self] in
            var freed: Int64 = 0, trashed: Int64 = 0, failures = 0
            for (n, i) in items.enumerated() {
                DispatchQueue.main.async { self?.cleaningStep = i.title; self?.cleaningDone = n }
                let r = Cleaner.clean(i, scannedAt: scannedAt)
                if r.trashed { trashed += r.bytes } else { freed += r.bytes }
                failures += r.failed.count
            }
            var text = tr("freed %1$@", ByteFormat.string(freed))
            if trashed > 0 { text += tr(", %1$@ moved to the Trash", ByteFormat.string(trashed)) }
            if failures > 0 { text += " · " + trCount(failures, "%1$@ path could not be removed (see log)", "%1$@ paths could not be removed (see log)") }
            DispatchQueue.main.async {
                guard let self else { return }
                self.cleaning = false
                self.cleaningStep = ""
                self.lastResult = text
                // Drop what was cleaned instead of rescanning the whole disk.
                let cleaned = Set(items.map(\.id))
                if var r = self.report {
                    r.items.removeAll { cleaned.contains($0.id) }
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

    func openFullDiskAccess() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    func reveal(_ item: CleanItem) {
        let urls = item.paths.prefix(20).map { URL(fileURLWithPath: $0) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(Array(urls)) }
    }

    func openLog() { NSWorkspace.shared.open(Cleaner.logURL) }
}

struct DiskView: View {
    @ObservedObject var model: DiskModel
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if model.scanning, model.report != nil {
                // Results stream in; say what is still being looked at.
                HStack(spacing: 6) {
                    Text(tr("scanning… %1$@", model.progress)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button(tr("Stop")) { model.stop() }.controlSize(.small).disabled(model.stopping)
                }
            }
            if let r = model.report, !model.scanning, r.cancelled {
                Text(tr("Scan stopped — showing what was found so far.")).font(.caption2).foregroundStyle(.orange)
            }
            if model.stale, !model.scanning {
                Text(tr("Scope changed — scan again to update the list.")).font(.caption2).foregroundStyle(.orange)
            }
            if let r = model.report {
                // Choosing what to remove happens in the Disk Cleanup window; here, just the picture.
                summary(r)
            } else if model.scanning {
                VStack(spacing: 6) {
                    if !renderingPreview { ProgressView().controlSize(.small) }
                    Text(model.progress).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Button(tr("Stop")) { model.stop() }.controlSize(.small).disabled(model.stopping)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                VStack(spacing: 10) {
                    Text(tr("Finds old AI sessions, model downloads and agent leftovers, plus the usual caches. Nothing is removed until you choose."))
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button(tr("Open Disk Cleanup…")) { DiskWindow.show(model) }.buttonStyle(.borderedProminent)
                    Text(tr("Runs at low priority; you can stop it any time and get a notification when it's done."))
                        .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .sheet(isPresented: $confirming) { confirmSheet }
    }

    /// The confirm sheet as shown for the current selection (also used by --render-preview).
    static func confirmPreview(_ model: DiskModel) -> some View {
        DiskView(model: model).confirmSheet
    }

    var confirmSheet: some View {
        ConfirmSheet(title: tr("Clean %1$@?", ByteFormat.string(model.selectedBytes)), summary: model.confirmSummary,
                     destructive: model.selectedItems.contains { $0.safety == .safe }, heading: tr("What will be removed"),
                     lines: model.planLines,
                     footnote: tr("Removed items are listed in ~/Library/Logs/Thermo/clean.log. Anything changed since the scan is skipped."),
                     confirmTitle: tr("Clean"),
                     confirm: { confirming = false; model.clean() }, cancel: { confirming = false })
    }

    var header: some View {
        HStack(alignment: .firstTextBaseline) {
            if let r = model.report {
                Text(ByteFormat.string(r.totalBytes)).font(.title3.monospacedDigit().weight(.semibold))
                Text(tr("reclaimable")).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(tr("Disk cleanup")).font(.headline)
            }
            Spacer()
            if renderingPreview {
                Text(model.scope.label).font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(.quaternary))
            } else {
                Picker("", selection: $model.scope) { ForEach(DiskModel.Scope.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 140)
                    .disabled(model.scanning || model.cleaning)
                if model.scanning {
                    Button { model.stop() } label: { Image(systemName: "stop.circle") }
                        .buttonStyle(.borderless).disabled(model.stopping).help(tr("Stop"))
                } else {
                    Button { model.scan() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).disabled(model.cleaning).help(tr("Scan again"))
                }
            }
        }
    }

    func icon(_ c: CleanCategory) -> String {
        switch c {
        case .aiSessions: return "bubble.left.and.text.bubble.right"
        case .aiModels: return "cpu"
        case .aiCaches: return "sparkles"
        case .devCaches: return "hammer"
        case .xcode: return "swift"
        case .projects: return "folder"
        case .browsers: return "globe"
        case .system: return "gearshape"
        }
    }

    func summary(_ r: ScanReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(CleanCategory.allCases, id: \.self) { c in
                let bytes = r.bytes(in: c)
                if bytes > 0 {
                    HStack {
                        Image(systemName: icon(c)).foregroundStyle(.secondary).frame(width: 18)
                        Text(c.title)
                        Spacer()
                        Text(ByteFormat.string(bytes)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
            if let res = model.lastResult {
                Text(res).font(.caption).foregroundStyle(.secondary).onTapGesture { model.openLog() }
            }
            if let days = r.claudeCleanupDays {
                Text(tr("Claude Code deletes its own sessions after %1$@ days (cleanupPeriodDays).", String(days)))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            HStack {
                Spacer()
                if renderingPreview {
                    Text(tr("Open Disk Cleanup…")).font(.callout).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor))
                } else {
                    Button(tr("Open Disk Cleanup…")) { DiskWindow.show(model) }
                        .modifier(ActionButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, 4)
        }
    }

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
