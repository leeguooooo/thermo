import AppKit
import CleanKit
import SwiftUI
import ThermoL10n

/// Scans in the background on demand (never at launch) and removes what the user ticks.
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
    @Published var scope: Scope = .ai
    @Published var lastResult: String?
    @Published var error: String?
    /// While cleaning: which item is being removed, and how far along we are.
    @Published private(set) var cleaningStep = ""
    @Published private(set) var cleaningDone = 0
    @Published private(set) var cleaningTotal = 0

    private let queue = DispatchQueue(label: "dev.thermo.app.disk", qos: .utility)

    /// What a clean would remove: ticked items, narrowed to the parts still ticked.
    var selectedItems: [CleanItem] {
        (report?.items ?? []).filter { selected.contains($0.id) && $0.cleanable }.compactMap { i in
            guard let off = excluded[i.id], !off.isEmpty, let parts = i.parts else { return i }
            let narrowed = i.only(Set(parts.map(\.id)).subtracting(off))
            return narrowed.bytes > 0 ? narrowed : nil
        }
    }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }

    func scanIfNeeded() { if report == nil && !scanning { scan() } }

    static let order = Dictionary(uniqueKeysWithValues: CleanCategory.allCases.enumerated().map { ($1, $0) })

    static func sorted(_ items: [CleanItem]) -> [CleanItem] {
        items.sorted { (order[$0.category]!, -$0.bytes, $0.id) < (order[$1.category]!, -$1.bytes, $1.id) }
    }

    func scan() {
        guard !scanning else { return }
        scanning = true
        progress = tr("starting…")
        report = nil
        selected = []
        excluded = [:]
        var options = ScanOptions()
        if scope == .ai { options.categories = Set(CleanCategory.allCases.filter(\.isAI)) }
        let scanner = DiskScanner(options: options)
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
            }
        }
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
                self.scan()
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
    @State private var expanded: Set<CleanCategory> = [.aiSessions]
    /// Items whose sessions are listed.
    @State private var openItems: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if model.scanning, model.report != nil {
                // Results stream in; say what is still being looked at.
                Text(tr("scanning… %1$@", model.progress)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            if let r = model.report {
                if renderingPreview { list(r) } else { ScrollView { list(r) }.frame(height: 330) }
                footer(r)
            } else if model.scanning {
                VStack(spacing: 6) {
                    if !renderingPreview { ProgressView().controlSize(.small) }
                    Text(model.progress).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Text(tr("Finds old AI sessions, model downloads and agent leftovers, plus the usual caches. Nothing is removed until you choose."))
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .onAppear { model.scanIfNeeded() }
        .sheet(isPresented: $confirming) { confirmSheet }
    }

    /// The confirm sheet as shown for the current selection (also used by --render-preview).
    static func confirmPreview(_ model: DiskModel) -> some View {
        DiskView(model: model).confirmSheet
    }

    var confirmSheet: some View {
        ConfirmSheet(title: tr("Clean %1$@?", ByteFormat.string(model.selectedBytes)), summary: confirmText,
                     destructive: model.selectedItems.contains { $0.safety == .safe }, heading: tr("What will be removed"),
                     lines: planLines,
                     footnote: tr("Removed items are listed in ~/Library/Logs/Thermo/clean.log. Anything changed since the scan is skipped."),
                     confirmTitle: tr("Clean"),
                     confirm: { confirming = false; model.clean() }, cancel: { confirming = false })
    }

    /// One line per item: how it goes, its size, its name and how many paths.
    var planLines: [String] {
        model.selectedItems.map { i in
            let how = i.safety == .safe ? tr("delete") : tr("trash")
            let paths = trCount(i.paths.count, "%1$@ path", "%1$@ paths")
            return "\(how.padding(toLength: 7, withPad: " ", startingAt: 0)) \(ByteFormat.string(i.bytes).padding(toLength: 9, withPad: " ", startingAt: 0)) \(i.title) (\(paths))"
        }
    }

    var confirmText: String {
        let items = model.selectedItems
        let trash = items.filter { $0.safety != .safe }
        var parts = [trCount(items.count, "%1$@ item.", "%1$@ items.")]
        if trash.count < items.count { parts.append(tr("Caches and build output are deleted.")) }
        if !trash.isEmpty {
            parts.append(trCount(trash.count, "%1$@ item with your data (sessions, models, worktrees) goes to the Trash.",
                                 "%1$@ items with your data (sessions, models, worktrees) go to the Trash."))
        }
        return parts.joined(separator: " ")
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
                    .onChange(of: model.scope) { _ in model.scan() }
                Button { model.scan() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(model.scanning || model.cleaning).help(tr("Scan again"))
            }
        }
    }

    func list(_ r: ScanReport) -> some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            if r.items.isEmpty {
                Text(tr("Nothing to clean.")).foregroundStyle(.secondary).padding(.vertical, 20)
            }
            ForEach(CleanCategory.allCases, id: \.self) { c in
                let items = r.items.filter { $0.category == c }
                if !items.isEmpty { section(c, items, total: r.bytes(in: c)) }
            }
            if let days = r.claudeCleanupDays {
                Text(tr("Claude Code deletes its own sessions after %1$@ days (cleanupPeriodDays).", String(days)))
                    .font(.caption2).foregroundStyle(.tertiary).padding(.top, 4)
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

    func section(_ c: CleanCategory, _ items: [CleanItem], total: Int64) -> some View {
        let open = expanded.contains(c)
        let ticked = items.filter { model.selected.contains($0.id) }.count
        return VStack(alignment: .leading, spacing: 3) {
            Button {
                if open { expanded.remove(c) } else { expanded.insert(c) }
            } label: {
                HStack {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 10)
                    Image(systemName: icon(c)).foregroundStyle(.secondary).frame(width: 16)
                    Text(c.title).font(.callout.bold())
                    if ticked > 0 { Text(tr("%1$@ selected", String(ticked))).font(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                    Text(ByteFormat.string(total)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            // Previews are a fixed-size image; a few rows show the layout.
            if open { ForEach(renderingPreview ? Array(items.prefix(5)) : items) { row($0) } }
        }
    }

    func row(_ i: CleanItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            itemRow(i)
            if let parts = i.parts, parts.count > 1, i.cleanable {
                let open = openItems.contains(i.id)
                let off = model.excluded[i.id]?.count ?? 0
                Button {
                    if open { openItems.remove(i.id) } else { openItems.insert(i.id) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 8))
                        Text(model.selected.contains(i.id) && off > 0
                             ? tr("%1$@ of %2$@ sessions selected", String(parts.count - off), String(parts.count))
                             : trCount(parts.count, "%1$@ session", "%1$@ sessions"))
                    }
                    .font(.caption2).foregroundStyle(.secondary).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 34)
                if open {
                    ForEach(renderingPreview ? Array(parts.prefix(4)) : parts) { p in partRow(p, of: i) }
                }
            }
        }
    }

    func partRow(_ p: CleanPart, of i: CleanItem) -> some View {
        let on = model.isTicked(p, of: i)
        return HStack(spacing: 6) {
            Image(systemName: on ? "checkmark.square.fill" : "square").font(.caption)
                .foregroundStyle(on ? Color.accentColor : .secondary)
                .onTapGesture { model.toggle(p, of: i) }
            Text(p.title).font(.caption).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            if let d = p.lastUsed { Text(AgeFormat.string(d)).font(.caption2).foregroundStyle(.tertiary) }
            Text(ByteFormat.string(p.bytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.leading, 46)
        .contextMenu {
            Button(tr("Show in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting(p.paths.prefix(20).map { URL(fileURLWithPath: $0) })
            }
            Button(tr("Copy ID")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("\(i.id)#\(p.id)", forType: .string) }
        }
    }

    func itemRow(_ i: CleanItem) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: model.selected.contains(i.id) ? "checkmark.square.fill" : "square")
                .foregroundStyle(i.cleanable ? (model.selected.contains(i.id) ? Color.accentColor : .secondary) : Color.secondary.opacity(0.4))
                .onTapGesture { if i.cleanable { model.toggle(i) } }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(i.title).font(.callout).lineLimit(1).truncationMode(.middle)
                    SafetyTag(safety: i.safety, info: i.paths.isEmpty)
                }
                Text([i.detail, i.lastUsed.map { AgeFormat.string($0) }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let b = i.blocked { Text(b).font(.caption2).foregroundStyle(.orange) }
                else if let h = i.hint { Text(tr("Run: %1$@", h)).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
                else if let n = i.note { Text(n).font(.caption2).foregroundStyle(.tertiary).lineLimit(2) }
            }
            Spacer(minLength: 4)
            let shown = model.selectedItems.first { $0.id == i.id }?.bytes ?? i.bytes
            Text(ByteFormat.string(shown)).font(.callout.monospacedDigit()).foregroundStyle(i.cleanable ? .primary : .secondary)
        }
        .padding(.leading, 12)
        .contextMenu {
            Button(tr("Show in Finder")) { model.reveal(i) }.disabled(i.paths.isEmpty)
            Button(tr("Copy ID")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(i.id, forType: .string) }
        }
        .help(i.paths.prefix(5).joined(separator: "\n") + (i.paths.count > 5 ? "\n… \(i.paths.count - 5) more" : ""))
    }

    func footer(_ r: ScanReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !r.denied.isEmpty {
                HStack {
                    Text(trCount(r.denied.count, "%1$@ location needs Full Disk Access.", "%1$@ locations need Full Disk Access."))
                        .font(.caption).foregroundStyle(.orange)
                    Spacer()
                    if !renderingPreview { Button(tr("Open Settings")) { model.openFullDiskAccess() }.controlSize(.small) }
                }
            }
            if let res = model.lastResult {
                Text(res).font(.caption).foregroundStyle(.secondary).onTapGesture { model.openLog() }
            }
            if renderingPreview {
                HStack {
                    Spacer()
                    Text(tr("Clean %1$@", ByteFormat.string(model.selectedBytes))).font(.callout).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor))
                }
            } else {
                HStack {
                    Button(tr("None")) { model.selected = [] }.controlSize(.small).modifier(ActionButtonStyle(prominent: false))
                        .disabled(model.selected.isEmpty)
                    Button(tr("Safe")) { model.selected = Set(r.items.filter { $0.cleanable && $0.safety == .safe }.map(\.id)) }
                        .controlSize(.small).modifier(ActionButtonStyle(prominent: false))
                    Spacer()
                    if model.cleaning {
                        ProgressView(value: Double(model.cleaningDone), total: Double(max(1, model.cleaningTotal)))
                            .frame(width: 50).controlSize(.small)
                            .help(tr("Cleaning %1$@ of %2$@: %3$@", String(model.cleaningDone + 1), String(model.cleaningTotal), model.cleaningStep))
                    }
                    Button(tr("Clean %1$@", ByteFormat.string(model.selectedBytes))) { confirming = true }
                        .modifier(ActionButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.selectedItems.isEmpty || model.cleaning || model.scanning)
                }
            }
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
