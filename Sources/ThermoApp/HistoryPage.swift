import AgentCore
import AppKit
import CleanKit
import SwiftUI
import ThermoL10n

@MainActor
final class HistoryModel: ObservableObject {
    static let shared = HistoryModel()
    @Published private(set) var records: [OperationRecord] = []
    @Published private(set) var loaded = false
    @Published var busy = false
    @Published var notice: String?

    private let reader: @Sendable () -> [OperationRecord]
    init(reader: @escaping @Sendable () -> [OperationRecord] = { OperationJournal.read(limit: 300) }) { self.reader = reader }

    func load() {
        let reader = reader
        Task.detached(priority: .userInitiated) {
            let records = reader()
            await MainActor.run { self.records = records; self.loaded = true }
        }
    }

    /// Puts a recorded Trash batch back; anything changed, missing or in the way is skipped and listed.
    func restore(_ record: OperationRecord) {
        guard !busy, record.undo?.kind == "trashBatch", let id = record.undo?.ref else { return }
        busy = true
        Task.detached(priority: .userInitiated) {
            let text: String
            do {
                let result = try TrashBatches.restore(id: id)
                let restored = result.items.filter { $0.status == "restored" }.count
                let others = result.items.filter { $0.status != "restored" }
                text = ([tr("%1$@ of %2$@ items put back.", String(restored), String(result.items.count))]
                        + others.map { FS.tilde($0.original) + ": " + ($0.reason ?? $0.status) }).joined(separator: "\n")
            } catch { text = error.localizedDescription }
            await MainActor.run { self.notice = text; self.busy = false; self.load() }
        }
    }
}

/// Every change Thermo made, newest first, each with where it is undone. Entries moved to the
/// Trash in a recorded batch are put back from here; the others open the place that restores them.
struct HistoryPage: View {
    @ObservedObject var model: HistoryModel
    let open: (MainPage) -> Void
    @State private var expanded: Set<String> = []
    @State private var restoring: OperationRecord?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        WindowPage(title: tr("History"), subtitle: tr("Every change Thermo made, and where to undo it.")) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text").foregroundStyle(.white.opacity(0.5)).accessibilityHidden(true)
                Text(FS.tilde(OperationJournal.url().path)).font(.system(size: 11).monospaced()).foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: 8)
                if model.busy { ProgressView().controlSize(.small) }
                Button { model.load() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
                    .accessibilityLabel(tr("Refresh")).help(tr("Refresh"))
            }
            .padding(.horizontal, 4)
            if let notice = model.notice { NoticeBanner(text: notice) { model.notice = nil } }
            if !model.loaded {
                NoticeBanner(text: tr("Reading the history…"), busy: true)
            } else if model.records.isEmpty {
                InspectorPanel {
                    Text(tr("No operations recorded yet. Cleanups, uninstalls, agent fixes, Claude resets, privacy changes and tab batches will appear here."))
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
                        .padding(16)
                }
            } else {
                ForEach(days, id: \.0) { day, records in
                    VStack(alignment: .leading, spacing: 6) {
                        SectionHeader(title: day)
                        InspectorPanel {
                            ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                                if index > 0 { InspectorDivider() }
                                row(record)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { model.load() }
        .sheet(item: $restoring) { record in restoreSheet(record) }
    }

    var days: [(String, [OperationRecord])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: model.records) { calendar.startOfDay(for: $0.time) }
        return groups.keys.sorted(by: >).map { day in
            let title = calendar.isDateInToday(day) ? tr("Today") : calendar.isDateInYesterday(day) ? tr("Yesterday")
                : day.formatted(date: .abbreviated, time: .omitted)
            return (title, groups[day]!.sorted { $0.time > $1.time })
        }
    }

    static func symbol(_ r: OperationRecord) -> String {
        switch r.feature {
        case "clean": return "sparkles"
        case "apps": return "square.grid.2x2"
        case "space": return "square.grid.3x3.topleft.filled"
        case "agents": return "stethoscope"
        case "claudeReset": return "arrow.counterclockwise.circle"
        case "privacy": return "hand.raised"
        case "tabs": return "rectangle.stack"
        case "worktrees": return "arrow.triangle.branch"
        case "archive": return "externaldrive.connected.to.line.below"
        case "pulse": return "stop.circle"
        case "history": return "arrow.uturn.backward"
        default: return "circle"
        }
    }

    func row(_ r: OperationRecord) -> some View {
        let open = expanded.contains(r.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: Self.symbol(r)).font(.system(size: 13)).foregroundStyle(.white.opacity(0.55))
                    .frame(width: 18).padding(.top, 1).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(r.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        if r.outcome != "succeeded" {
                            RequirementTag(text: r.outcomeText, warning: true)
                        }
                    }
                    Text(([r.time.formatted(date: .omitted, time: .shortened), r.subject, r.items.count > 1 ? tr("%1$@ items", String(r.items.count)) : nil, r.sizeText]
                        .compactMap { $0 }).joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1).truncationMode(.middle)
                    if let undo = r.restorableHere ? tr("Can be put back from here.") : r.undoText {
                        Text(undo).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                action(r)
                Button { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { if open { expanded.remove(r.id) } else { expanded.insert(r.id) } } } label: {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.45))
                .accessibilityLabel(open ? tr("Hide details") : tr("Show details")).accessibilityHint(r.title)
            }
            if open {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(r.items.prefix(200).enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: item.status == "done" ? "checkmark" : item.status == "skipped" ? "minus" : item.status == "partial" ? "circle.lefthalf.filled" : "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(item.status == "failed" ? Color.orange : .white.opacity(0.5)).frame(width: 12)
                                .accessibilityLabel(item.status)
                            Text(item.target).font(.system(size: 11).monospaced()).foregroundStyle(.white.opacity(0.7))
                                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                            if let bytes = item.bytes {
                                Text(ByteFormat.string(bytes)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.white.opacity(0.45))
                            }
                        }
                        if let detail = item.detail, !detail.isEmpty {
                            Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).padding(.leading, 18)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                    if r.items.count > 200 {
                        Text(tr("%1$@ more in thermo history show %2$@", String(r.items.count - 200), String(r.id.prefix(8))))
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                    }
                }
                .padding(.leading, 28).padding(.top, 8)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// The one button an entry gets: put back here, or go to where it is restored.
    @ViewBuilder func action(_ r: OperationRecord) -> some View {
        switch r.undo?.kind {
        case "nativeUpdate":
            Button(tr("Open")) {
                AppModels.shared.softwareUpdates.channel = "native"
                AppModels.shared.nativeUpdates.showRecovery = true
                open(.apps(.updates))
            }.buttonStyle(PillButtonStyle()).fixedSize()
        case nil where r.feature == "apps" && r.action == "update":
            Button(tr("Open")) { open(.apps(.updates)) }.buttonStyle(PillButtonStyle()).fixedSize()
        case "startup":
            Button(tr("Open")) { open(.apps(.startup)) }.buttonStyle(PillButtonStyle()).fixedSize()
        case "trashBatch":
            Button(tr("Restore…")) { restoring = r }.buttonStyle(PillButtonStyle()).disabled(model.busy).fixedSize()
        case "claudeReset":
            Button(tr("Open")) { open(.claudeCleanup) }.buttonStyle(PillButtonStyle()).fixedSize()
        case "browserBackup", "timezoneBackup":
            Button(tr("Open")) { open(.privacyTools) }.buttonStyle(PillButtonStyle()).fixedSize()
        case "tabArchive", "tabBatch":
            Button(tr("Open")) { open(.browser("Google Chrome")) }.buttonStyle(PillButtonStyle()).fixedSize()
        case "trash":
            Button(tr("Open Trash")) {
                NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash"))
            }.buttonStyle(PillButtonStyle()).fixedSize()
        case "agentBackup", "worktreeBackup":
            if let ref = r.undo?.ref {
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: ref)]) } label: { Image(systemName: "folder") }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6))
                    .accessibilityLabel(tr("Reveal in Finder")).help(tr("Reveal in Finder"))
            }
        default: EmptyView()
        }
    }

    func restoreSheet(_ r: OperationRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("Put these back from the Trash?")).font(.system(size: 17, weight: .bold))
            Text(r.title + (r.subject.map { " · " + $0 } ?? "")).font(.system(size: 12)).foregroundStyle(.secondary)
            InspectorPanel {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(r.items.filter { $0.status == "done" || $0.status == "partial" }.prefix(100).enumerated()), id: \.offset) { _, item in
                            Text(FS.tilde(item.target)).font(.system(size: 11).monospaced()).lineLimit(1).truncationMode(.middle)
                        }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 200)
            }
            Text(tr("Each item goes back only if it is still in the Trash unchanged and nothing new is at its original place; anything else is skipped and listed."))
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(tr("Cancel")) { restoring = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(tr("Restore")) { restoring = nil; model.restore(r) }.buttonStyle(PillButtonStyle(prominent: true))
            }
        }
        .padding(24).frame(width: 520)
        .background(Color(red: 0.09, green: 0.10, blue: 0.18))
        .preferredColorScheme(.dark)
    }
}
