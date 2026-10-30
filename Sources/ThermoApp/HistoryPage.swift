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
    @Published private(set) var reading = false
    @Published private(set) var readIssue: String?
    @Published var busy = false
    @Published var notice: String?
    @Published private(set) var restoreReview: TrashRestore?
    @Published private(set) var restoreReviewIssue: String?
    @Published private(set) var reviewingRestore = false
    private var restoreReviewGeneration = UUID(), restoreReviewInFlight = false
    private var restoreReviewTarget: String?
    private var pendingRestoreReview: OperationRecord?
    private let reviewBatch: @Sendable (String) throws -> TrashRestore

    private let reader: @Sendable () -> OperationJournal.ReadReport
    private var readAgain = false
    private let restoreBatch: @Sendable (String, TrashRestore) throws -> TrashRestore
    private let didRestore: @MainActor ([String]) -> Void
    init(reader: @escaping @Sendable () -> OperationJournal.ReadReport = { OperationJournal.readReport(limit: 300) },
         reviewBatch: @escaping @Sendable (String) throws -> TrashRestore = { try TrashBatches.restore(id: $0, dryRun: true) },
         restoreBatch: @escaping @Sendable (String, TrashRestore) throws -> TrashRestore = { id, review in
             try TrashBatches.restore(id: id, reviewIdentity: review.reviewIdentity,
                 reviewedDestinations: Set(review.items.filter { $0.status == "restored" }.map(\.destination)))
         },
         didRestore: @escaping @MainActor ([String]) -> Void = {
             AppModels.shared.apps.invalidateAfterRestore()
             SpaceLensModel.shared.invalidateAfterRestore($0)
         }) {
        self.reader = reader; self.reviewBatch = reviewBatch; self.restoreBatch = restoreBatch; self.didRestore = didRestore
    }

    func load() {
        guard !reading else { readAgain = true; return }
        reading = true
        let reader = reader
        Task.detached(priority: .userInitiated) {
            let report = reader()
            await MainActor.run {
                self.reading = false
                if self.readAgain { self.readAgain = false; self.load(); return }
                if report.complete { self.records = report.records }
                else {
                    var seen = Set<String>()
                    self.records = Array((report.records + self.records).filter { seen.insert($0.id).inserted }
                        .sorted { $0.time > $1.time }.prefix(300))
                }
                self.readIssue = report.complete ? nil : tr("History is incomplete: %1$@", report.issues.joined(separator: "\n"))
                self.loaded = true
            }
        }
    }

    func prepareRestore(_ record: OperationRecord) {
        guard !busy, record.undo?.kind == "trashBatch", let id = record.undo?.ref else { return }
        restoreReviewTarget = id
        restoreReviewGeneration = UUID(); restoreReview = nil; restoreReviewIssue = nil; reviewingRestore = true
        if restoreReviewInFlight { pendingRestoreReview = record; return }
        readRestoreReview(record)
    }

    private func readRestoreReview(_ record: OperationRecord) {
        guard let id = record.undo?.ref else { return }
        let generation = restoreReviewGeneration, reviewBatch = reviewBatch
        restoreReviewInFlight = true
        Task.detached(priority: .userInitiated) {
            let result = Result { try reviewBatch(id) }
            await MainActor.run {
                self.restoreReviewInFlight = false
                if let pending = self.pendingRestoreReview {
                    self.pendingRestoreReview = nil; self.readRestoreReview(pending); return
                }
                guard self.restoreReviewGeneration == generation else { return }
                self.reviewingRestore = false
                switch result {
                case .success(let review) where review.id == id && review.dryRun && review.reviewIdentity != nil:
                    self.restoreReview = review
                case .success:
                    self.restoreReviewIssue = tr("Restore review is unavailable; review the batch again.")
                case .failure(let error): self.restoreReviewIssue = error.localizedDescription
                }
            }
        }
    }

    func cancelRestoreReview(for id: String? = nil) {
        guard id == nil || restoreReviewTarget == id else { return }
        restoreReviewTarget = nil
        restoreReviewGeneration = UUID(); pendingRestoreReview = nil
        restoreReview = nil; restoreReviewIssue = nil; reviewingRestore = false
    }

    /// Puts recorded items back; replacements, missing items and original-path conflicts are skipped.
    func restore(_ record: OperationRecord, review: TrashRestore) {
        guard !busy, record.undo?.kind == "trashBatch", let id = record.undo?.ref else { return }
        guard review.id == id, review.dryRun, review.reviewIdentity != nil,
              review.items.contains(where: { $0.status == "restored" }) else {
            notice = tr("Restore review is unavailable; review the batch again."); return
        }
        busy = true
        let exitGuard = AppExitGuard.beginRestore()
        let restoreBatch = self.restoreBatch
        Task.detached(priority: .userInitiated) {
            let text: String
            var paths: [String] = []
            do {
                let result = try restoreBatch(id, review)
                paths = result.items.filter { $0.status == "restored" }.map(\.original)
                let restored = result.items.filter { $0.status == "restored" }.count
                let already = result.items.filter { $0.status == "alreadyRestored" }.count
                let others = result.items.filter { $0.status != "restored" && $0.status != "alreadyRestored" }
                text = ([tr("%1$@ of %2$@ items put back.", String(restored), String(result.items.count - already))]
                        + (already > 0 ? [tr("%1$@ items were already at their original locations.", String(already))] : [])
                        + others.map { FS.tilde($0.original) + ": " + ($0.reason ?? $0.status) } + (result.issues ?? [])).joined(separator: "\n")
            } catch { text = error.localizedDescription }
            let restoredPaths = paths
            await MainActor.run {
                if !restoredPaths.isEmpty { self.didRestore(restoredPaths) }
                self.notice = text; self.busy = false
                AppExitGuard.endRestore(exitGuard)
                self.load()
            }
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
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
                Text(FS.tilde(OperationJournal.url().path)).font(Theme.mono).foregroundStyle(Theme.textTertiary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: Theme.Space.s)
                if model.busy || model.reading { ProgressView().controlSize(.small) }
                Button { model.load() } label: { Label(tr("Refresh"), systemImage: "arrow.clockwise") }
                    .buttonStyle(PillButtonStyle()).controlSize(.small)
                    .help(tr("Refresh"))
                    .disabled(model.busy || model.reading)
            }
            .padding(.horizontal, 2)
            if let notice = model.notice { NoticeBanner(text: notice) { model.notice = nil } }
            if let issue = model.readIssue { NoticeBanner(text: issue) }
            if !model.loaded {
                SkeletonList(rows: 5)
            } else if model.records.isEmpty {
                InspectorPanel {
                    EmptyState(symbol: "clock.arrow.circlepath",
                               title: tr(model.readIssue == nil ? "No operations recorded yet. Cleanups, uninstalls, agent fixes, Claude resets, privacy changes and tab batches will appear here." : "No verified history records are available."))
                }
            } else {
                ForEach(days, id: \.0) { day, records in
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        SectionHeader(title: day) {
                            Text(trCount(records.count, "%1$@ item", "%1$@ items")).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        }
                        InspectorPanel {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                                    if index > 0 { InspectorDivider(inset: 42) }
                                    row(record)
                                }
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
        let failed = r.outcome != "succeeded"
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                Image(systemName: Self.symbol(r)).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(failed ? Theme.caution : Theme.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.06)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(r.title).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary)
                        if failed { StatusTag(text: r.outcomeText, color: Theme.caution) }
                    }
                    Text(([r.time.formatted(date: .omitted, time: .shortened), r.subject, r.items.count > 1 ? tr("%1$@ items", String(r.items.count)) : nil, r.sizeText]
                        .compactMap { $0 }).joined(separator: " · "))
                        .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: Theme.Space.s)
                action(r)
                Button { withAnimation(Theme.standard.unlessReduced(reduceMotion)) { if open { expanded.remove(r.id) } else { expanded.insert(r.id) } } } label: {
                    DisclosureChevron(expanded: open).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(open ? tr("Hide details") : tr("Show details")).accessibilityHint(r.title)
            }
            if open {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    if let undo = r.restorableHere ? tr("Can be put back from here.") : r.undoText {
                        Label(undo, systemImage: "arrow.uturn.backward").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true).padding(.bottom, Theme.Space.xs)
                    }
                    ForEach(Array(r.items.prefix(200).enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: item.status == "done" ? "checkmark" : item.status == "skipped" ? "minus" : item.status == "partial" ? "circle.lefthalf.filled" : "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(item.status == "failed" ? Theme.caution : Theme.textTertiary).frame(width: 12)
                                .accessibilityLabel(item.status)
                            Text(item.target).font(Theme.mono).foregroundStyle(Theme.textSecondary)
                                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                            if let bytes = item.bytes {
                                Text(ByteFormat.string(bytes)).font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                            }
                        }
                        if let detail = item.detail, !detail.isEmpty {
                            Text(tr(detail)).font(Theme.caption).foregroundStyle(Theme.textTertiary).padding(.leading, 18)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                    if r.items.count > 200 {
                        Text(tr("%1$@ more in thermo history show %2$@", String(r.items.count - 200), String(r.id.prefix(8))))
                            .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.leading, 36).padding(.top, Theme.Space.s)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, Theme.Space.m + 2).padding(.vertical, Theme.Space.s + 2)
        .hoverHighlight()
    }

    /// The one button an entry gets: put back here, or go to where it is restored.
    @ViewBuilder func action(_ r: OperationRecord) -> some View {
        switch r.undo?.kind {
        case "nativeUpdate", "nativePreparation":
            Button(tr("Open")) {
                AppModels.shared.softwareUpdates.channel = "native"
                AppModels.shared.nativeUpdates.showRecovery = true
                open(.apps(.updates))
            }.buttonStyle(PillButtonStyle()).controlSize(.small).fixedSize()
        case nil where r.feature == "apps" && r.action == "update":
            Button(tr("Open")) { open(.apps(.updates)) }.buttonStyle(PillButtonStyle()).controlSize(.small).fixedSize()
        case "startup":
            Button(tr("Open")) { open(.apps(.startup)) }.buttonStyle(PillButtonStyle()).controlSize(.small).fixedSize()
        case "trashBatch":
            Button(tr("Restore…")) { restoring = r }.buttonStyle(PillButtonStyle()).controlSize(.small).disabled(model.busy).fixedSize()
        case "claudeReset":
            Button(tr("Open")) { open(.claude(.reset)) }.buttonStyle(PillButtonStyle()).controlSize(.small).fixedSize()
        case "browserBackup", "timezoneBackup":
            Button(tr("Open")) { open(.claude(.privacy)) }.buttonStyle(PillButtonStyle()).controlSize(.small).fixedSize()
        case "spotlightShortcut":
            Button(tr("Open")) { LocalSearchPanel.shared.show(settings: true) }.buttonStyle(PillButtonStyle()).controlSize(.small).fixedSize()
        case "tabArchive", "tabBatch":
            Button(tr("Open")) { open(.browser("Google Chrome")) }.buttonStyle(PillButtonStyle()).controlSize(.small).fixedSize()
        case "trash":
            Button(tr("Open Trash")) {
                NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash"))
            }.buttonStyle(PillButtonStyle()).controlSize(.small).fixedSize()
        case "agentBackup", "worktreeBackup":
            if let ref = r.undo?.ref {
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: ref)]) } label: { Image(systemName: "folder") }
                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                    .accessibilityLabel(tr("Reveal in Finder")).help(tr("Reveal in Finder"))
            }
        default: EmptyView()
        }
    }

    func restoreSheet(_ r: OperationRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("Put these back from the Trash?")).font(Theme.heading)
            Text(r.title + (r.subject.map { " · " + $0 } ?? "")).font(Theme.secondary).foregroundStyle(Theme.textSecondary)
            if model.reviewingRestore { NoticeBanner(text: tr("Reviewing the current Trash batch…"), busy: true) }
            if let issue = model.restoreReviewIssue { NoticeBanner(text: issue) }
            if let review = model.restoreReview {
                InspectorPanel {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(review.items.enumerated()), id: \.offset) { _, item in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(FS.tilde(item.original)).font(Theme.mono).textSelection(.enabled)
                                    if item.status != "restored" {
                                        Text(item.reason ?? tr("This item will stay in the Trash")).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                                    }
                                }
                            }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(minHeight: 100, maxHeight: 240)
                }
            }
            Text(tr("Only recorded items still in the Trash are put back when their original locations are empty; other items are skipped and listed."))
                .font(Theme.secondary).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(tr("Cancel")) { restoring = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(tr("Restore")) {
                    if let review = model.restoreReview { restoring = nil; model.restore(r, review: review) }
                }.buttonStyle(PillButtonStyle(prominent: true))
                    .disabled(model.busy || model.reviewingRestore || model.restoreReview?.items.contains(where: { $0.status == "restored" }) != true)
            }
        }
        .onAppear { model.prepareRestore(r) }
        .onDisappear { model.cancelRestoreReview(for: r.undo?.ref) }
        .padding(24).frame(width: 520)
        .background(Theme.canvas)
        .preferredColorScheme(.dark)
    }
}
