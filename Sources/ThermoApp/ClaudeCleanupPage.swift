import AppKit
import CleanKit
import SwiftUI

@MainActor
final class ClaudeCleanupModel: ObservableObject {
    lazy var privacy = PrivacyToolsModel()
    @Published var candidates: [ClaudeResetCandidate] = []
    @Published var selected: Set<ClaudeResetTarget> = []
    @Published var batches: [ClaudeResetBatch] = []
    @Published var loaded = false
    @Published var busy = false
    @Published var outcome: String?

    var picked: [ClaudeResetCandidate] { candidates.filter { selected.contains($0.target) && $0.status == .available } }

    func scan() {
        guard !busy else { return }
        busy = true
        selected = []
        Task.detached(priority: .userInitiated) {
            let service = ClaudeCleanup()
            let candidates = service.scan()
            let batches = service.batches()
            await MainActor.run {
                self.candidates = candidates
                self.batches = batches
                self.loaded = true
                self.busy = false
            }
        }
    }

    func toggle(_ candidate: ClaudeResetCandidate) {
        guard !busy, candidate.status == .available else { return }
        if selected.remove(candidate.target) != nil { return }
        let family = candidate.target.family
        // A folder reset and a file reset within that folder are alternatives.
        if candidate.target.isFolder {
            selected = selected.filter { $0.family != family }
        } else {
            selected = selected.filter { !($0.family == family && $0.isFolder) }
        }
        selected.insert(candidate.target)
    }

    func reset(_ plan: [ClaudeResetCandidate]) {
        guard !busy, !plan.isEmpty else { return }
        busy = true
        selected = []
        Task.detached(priority: .userInitiated) {
            let result = ClaudeCleanup().reset(plan)
            await MainActor.run {
                self.outcome = Self.summary(result)
                self.busy = false
                self.scan()
            }
        }
    }

    func restore(_ batch: ClaudeResetBatch) {
        guard !busy else { return }
        busy = true
        Task.detached(priority: .userInitiated) {
            let result = ClaudeCleanup().restore(batchID: batch.id)
            await MainActor.run {
                self.outcome = Self.summary(result)
                self.busy = false
                self.scan()
            }
        }
    }

    nonisolated static func summary(_ result: ClaudeResetResult) -> String {
        var lines = [tr("%1$@ items completed", String(result.succeeded.count))]
        if let batch = result.batch { lines.append(tr("Recovery record: %1$@", batch.id)) }
        lines += result.failed.sorted { $0.key < $1.key }.map { entry in
            let title = ClaudeResetTarget(rawValue: entry.key)?.title ?? tr("Claude reset")
            return title + ": " + tr(entry.value)
        }
        return lines.joined(separator: "\n")
    }
}

extension ClaudeResetTarget {
    var family: String {
        switch self {
        case .credentials, .settings, .codeData: return "code"
        case .globalConfig: return "global"
        case .desktopIdentity, .desktopData: return "desktop"
        case .thirdPartyIdentity, .thirdPartyData: return "third-party"
        }
    }
    var isFolder: Bool { [.codeData, .desktopData, .thirdPartyData].contains(self) }
    var title: String {
        switch self {
        case .credentials: return tr("Claude Code login file")
        case .settings: return tr("Claude Code user settings")
        case .globalConfig: return tr("Claude Code global state")
        case .codeData: return tr("Claude Code data folder")
        case .desktopIdentity: return tr("Claude desktop device identifier")
        case .desktopData: return tr("Claude desktop data folder")
        case .thirdPartyIdentity: return tr("Claude-3p device identifier")
        case .thirdPartyData: return tr("Claude-3p data folder")
        }
    }
    var impact: String {
        switch self {
        case .credentials: return tr("May require signing in again. macOS Keychain entries are kept.")
        case .settings: return tr("Resets user permissions, hooks and preferences in settings.json.")
        case .globalConfig: return tr("Resets global state, project trust and MCP configuration in .claude.json.")
        case .codeData: return tr("Moves the entire .claude folder, including sessions, plugins and settings. Project folders and .claude.json are kept.")
        case .desktopIdentity, .thirdPartyIdentity: return tr("Moves ant-did. The app may generate a new local identifier on its next launch.")
        case .desktopData, .thirdPartyData: return tr("Moves all local app data, including login state, conversations, preferences and caches.")
        }
    }
}


extension ClaudeResetTarget {
    var symbol: String {
        switch self {
        case .credentials: return "key"
        case .settings: return "slider.horizontal.3"
        case .globalConfig: return "doc.text"
        case .codeData, .desktopData, .thirdPartyData: return "folder"
        case .desktopIdentity, .thirdPartyIdentity: return "person.text.rectangle"
        }
    }
    /// The row title inside its group; the full `title` is the accessible name and is used in confirmations.
    var shortTitle: String {
        switch self {
        case .credentials: return tr("Login file")
        case .settings: return tr("User settings")
        case .globalConfig: return tr("Global state")
        case .codeData, .desktopData, .thirdPartyData: return tr("Data folder")
        case .desktopIdentity, .thirdPartyIdentity: return tr("Device identifier")
        }
    }
    /// One line on the row; `impact` is shown in full when the row is expanded and before any reset.
    var brief: String {
        switch self {
        case .credentials: return tr("May require signing in again.")
        case .settings: return tr("Permissions, hooks and preferences.")
        case .globalConfig: return tr("Global state, project trust and MCP servers in .claude.json.")
        case .codeData: return tr("The whole .claude folder, including the two files above.")
        case .desktopIdentity, .thirdPartyIdentity: return tr("A new identifier may be created on next launch.")
        case .desktopData, .thirdPartyData: return tr("All app data, including the identifier above.")
        }
    }
    /// A folder reset and the files inside it are alternatives (see `ClaudeCleanupModel.toggle`).
    var alternativeNote: String? {
        switch self {
        case .codeData: return tr("Includes the login file and user settings above; .claude.json is not included. Choose the folder or individual files.")
        case .desktopData, .thirdPartyData: return tr("Includes the device identifier above. Choose the folder or the identifier.")
        default: return nil
        }
    }
}

/// The page's three groups; only presentation, selection rules stay in the model.
private enum ResetGroup: CaseIterable {
    case code, desktop, thirdParty
    var title: String {
        switch self {
        case .code: return "Claude Code"
        case .desktop: return tr("Claude desktop")
        case .thirdParty: return "Claude-3p"
        }
    }
    var targets: [ClaudeResetTarget] {
        switch self {
        case .code: return [.credentials, .settings, .codeData, .globalConfig]
        case .desktop: return [.desktopIdentity, .desktopData]
        case .thirdParty: return [.thirdPartyIdentity, .thirdPartyData]
        }
    }
}

extension ClaudeCleanupModel {
    /// Bytes on disk at the scanned locations, counting a folder once instead of adding the files inside it.
    var localBytes: Int64 {
        Dictionary(grouping: candidates.filter { $0.status != .missing }, by: \.target.family).values.reduce(0) { total, items in
            total + (items.first { $0.target.isFolder && $0.snapshot != nil }?.bytes ?? items.reduce(0) { $0 + $1.bytes })
        }
    }
    /// Whether some existing item could not be measured, so `localBytes` is only a lower bound.
    var partiallyMeasured: Bool { candidates.contains { $0.status != .missing && $0.snapshot == nil } }
    var pickedBytes: Int64 { picked.reduce(0) { $0 + $1.bytes } }
    var blocked: [ClaudeResetCandidate] { candidates.filter { $0.status == .blocked } }
}

extension ClaudeCleanupModel {
    /// A file inside a folder that is picked goes with the folder, so it counts as picked.
    func covered(_ target: ClaudeResetTarget) -> Bool {
        !target.isFolder && selected.contains { $0.family == target.family && $0.isFolder }
    }
    func picked(_ target: ClaudeResetTarget) -> Bool { selected.contains(target) || covered(target) }

    /// Picks every available item of `items` through `toggle`, so its folder-or-files rule still
    /// decides: files first, then folders, which take their files' place.
    func pickAll(_ items: [ClaudeResetCandidate]) {
        let open = items.filter { $0.status == .available && !picked($0.target) }
        for candidate in open.sorted(by: { !$0.target.isFolder && $1.target.isFolder }) where !picked(candidate.target) {
            toggle(candidate)
        }
    }

    func clear(_ items: [ClaudeResetCandidate]) {
        guard !busy else { return }
        let targets = Set(items.map(\.target))
        selected.subtract(targets)
    }
}

// MARK: - Page

struct ClaudeCleanupPage: View {
    @ObservedObject var model: ClaudeCleanupModel
    @State private var tab = 0
    @State private var review: [ClaudeResetCandidate] = []
    @State private var confirming = false
    @State private var confirmation = ""
    @State private var restoring: ClaudeResetBatch?
    @State private var expanded: Set<ClaudeResetTarget> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: ClaudeCleanupModel, initialTab: Int = 0) {
        self.model = model
        self._tab = State(initialValue: initialTab)
    }

    var body: some View {
        WindowPage(title: tr("Claude cleanup"), subtitle: tr("Review local Claude data, browser privacy and network settings.")) {
            ThermoTabs(selection: $tab, options: [(0, tr("Claude reset")), (1, tr("Privacy & network"))], label: tr("Tools"))
            if tab == 0 { resetContent.transition(.opacity) } else { PrivacyToolsView(model: model.privacy).transition(.opacity) }
        }
        .animation(Theme.standard.unlessReduced(reduceMotion), value: tab)
        .safeAreaInset(edge: .bottom, spacing: 0) { if tab == 0 { actionBar } }
        .onAppear { if !model.loaded { model.scan() } }
        .sheet(isPresented: $confirming) {
            ClaudeResetConfirmation(items: review.map { .init(target: $0.target, path: $0.path, bytes: $0.bytes) },
                                    confirmation: $confirmation, busy: model.busy,
                                    cancel: { confirming = false },
                                    confirm: {
                                        let plan = review
                                        confirming = false
                                        model.reset(plan)
                                    })
        }
        .sheet(item: $restoring) { batch in
            ClaudeRestoreConfirmation(batch: batch, cancel: { restoring = nil }, confirm: { restoring = nil; model.restore(batch) })
        }
    }

    // MARK: Reset tab

    var available: [ClaudeResetCandidate] { model.candidates.filter { $0.status == .available } }

    var resetContent: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            summary
            if let outcome = model.outcome {
                NoticeBanner(text: outcome) { model.outcome = nil }
            }
            if !model.loaded {
                SkeletonList(rows: 4)
            }
            ForEach(Array(ResetGroup.allCases.enumerated()), id: \.offset) { _, group in
                let rows = group.targets.compactMap { target in model.candidates.first { $0.target == target } }
                if !rows.isEmpty {
                    let open = rows.filter { $0.status == .available }
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        HStack {
                            SelectAllButton(title: group.title, available: open.count,
                                            selected: open.filter { model.picked($0.target) }.count,
                                            selectAll: { model.pickAll(rows) }, clear: { model.clear(rows) })
                                .disabled(model.busy)
                            Spacer()
                            Text(ByteFormat.string(groupBytes(rows))).font(Theme.caption.monospacedDigit())
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .padding(.leading, Theme.Space.m + 6).padding(.trailing, Theme.Space.xs).padding(.top, Theme.Space.xs)
                        InspectorPanel {
                            ForEach(Array(rows.enumerated()), id: \.element.target) { index, candidate in
                                if index > 0 { InspectorDivider(inset: 50) }
                                candidateRow(candidate)
                            }
                        }
                    }
                }
            }
            recovery.padding(.top, Theme.Space.s)
        }
    }

    /// A folder counts once instead of adding the files inside it.
    func groupBytes(_ rows: [ClaudeResetCandidate]) -> Int64 {
        let present = rows.filter { $0.status != .missing }
        return present.first { $0.target.isFolder && $0.snapshot != nil }?.bytes ?? present.reduce(0) { $0 + $1.bytes }
    }

    /// The page's one figure, how much local Claude data there is, then what can and cannot be reset.
    var summary: some View {
        InspectorPanel {
            HStack(alignment: .bottom, spacing: Theme.Space.xl + 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.loaded ? (model.partiallyMeasured ? "≥ " : "") + ByteFormat.string(model.localBytes) : "—")
                        .font(Theme.figure(.hero)).foregroundStyle(Theme.textPrimary).contentTransition(.numericText())
                    Text(model.partiallyMeasured ? tr("Measured local data") : tr("Local data"))
                        .font(Theme.label).foregroundStyle(Theme.textTertiary)
                }
                metric(model.loaded ? String(available.count) : "—", tr("Can reset"))
                metric(model.loaded ? String(model.blocked.count) : "—", tr("Locked"), warning: !model.blocked.isEmpty)
                Spacer(minLength: Theme.Space.s)
                HStack(spacing: Theme.Space.s) {
                    InfoButton(text: tr("Known locations only; project folders are kept."))
                    if model.busy { ProgressView().controlSize(.small) }
                    Button(tr("Scan again")) { model.scan() }
                        .buttonStyle(PillButtonStyle()).controlSize(.small)
                        .disabled(model.busy)
                }
                .padding(.bottom, 2)
            }
            .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m + 2)
            InspectorDivider(inset: 0)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let lock = lockExplanation {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                        Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(Theme.caution).frame(width: 14)
                            .accessibilityHidden(true)
                        (Text(lock.reason).fontWeight(.semibold).foregroundColor(Theme.textPrimary) + Text("  ") + Text(lock.fix).foregroundColor(Theme.textSecondary))
                            .font(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(Theme.textTertiary).frame(width: 14)
                        .accessibilityHidden(true)
                    Text(tr("Resetting local state can sign you out or remove local history. Nothing is selected automatically."))
                        .font(Theme.secondary).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One explanation for every locked item, with how to unlock it; per-item reasons stay in each row.
    var lockExplanation: (reason: String, fix: String)? {
        let reasons = model.blocked.map { $0.reason ?? tr("Locked") }
        let counts = Dictionary(reasons.map { ($0, 1) }, uniquingKeysWith: +)
        guard let main = counts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) else { return nil }
        let others = reasons.count - main.value
        if others == 0 { return (tr(main.key), tr("Resolve this, then scan again. Locked items cannot be selected.")) }
        return (tr(main.key), tr("%1$@ more items are locked for other reasons. Expand them to see why, then scan again.", String(others)))
    }

    func metric(_ value: String, _ label: String, warning: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Theme.figure(.metric)).foregroundStyle(warning ? Theme.caution : Theme.textPrimary)
                .contentTransition(.numericText())
            Text(label).font(Theme.label).foregroundStyle(Theme.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }

    func toggleOpen(_ target: ClaudeResetTarget) {
        withAnimation(Theme.standard.unlessReduced(reduceMotion)) {
            if expanded.contains(target) { expanded.remove(target) } else { expanded.insert(target) }
        }
    }

    func candidateRow(_ candidate: ClaudeResetCandidate) -> some View {
        let target = candidate.target
        let open = expanded.contains(target)
        let missing = candidate.status == .missing
        let covered = model.covered(target)
        let on = model.selected.contains(target)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                Button { model.toggle(candidate) } label: {
                    // A file inside a picked folder shows a dash: it goes with the folder.
                    SelectionBox(state: on ? .all : covered ? .some : .none, locked: candidate.status == .blocked)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.busy || candidate.status != .available)
                .opacity(missing ? 0.35 : 1)
                .accessibilityLabel(target.title)
                .accessibilityValue(on || covered ? tr("Selected") : tr("Not selected"))
                .accessibilityHint(target.impact)
                Image(systemName: target.symbol).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                    .frame(width: 16).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.shortTitle).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary)
                    Text(target.brief).font(Theme.secondary).foregroundStyle(Theme.textTertiary)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: Theme.Space.s)
                if candidate.status == .blocked {
                    StatusTag(text: tr("Locked"), color: Theme.caution)
                        .help(candidate.reason.map { tr($0) } ?? tr("Locked"))
                        .accessibilityHint(candidate.reason.map { tr($0) } ?? "")
                }
                Text(missing ? tr("Not found") : candidate.snapshot == nil ? "—" : ByteFormat.string(candidate.bytes))
                    .font(Theme.figure(.row, weight: .medium)).foregroundStyle(missing ? Theme.textTertiary : Theme.textSecondary)
                    .fixedSize()
                Button { toggleOpen(target) } label: { DisclosureChevron(expanded: open) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(open ? tr("Hide details") : tr("Show details"))
                    .accessibilityHint(target.title)
            }
            .contentShape(Rectangle())
            .onTapGesture { toggleOpen(target) }
            if open {
                VStack(alignment: .leading, spacing: Theme.Space.xs + 2) {
                    Text(target.impact).font(Theme.secondary).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note = target.alternativeNote {
                        Text(note).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(FS.tilde(candidate.path)).font(Theme.mono).foregroundStyle(Theme.textTertiary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if let reason = candidate.reason {
                        Label(tr(reason), systemImage: "lock.fill").font(Theme.caption).foregroundStyle(Theme.caution)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 64).padding(.top, Theme.Space.s)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, Theme.Space.m + 2).padding(.vertical, Theme.Space.s + 2)
        .opacity(missing ? 0.6 : 1)
        .hoverHighlight()
    }

    // MARK: Recovery

    var recovery: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader(title: tr("Recovery records")) {
                HStack(spacing: Theme.Space.s) {
                    InfoButton(text: tr("Reset data stays in a private recovery folder and still uses disk space. Restore it here before removing any recovery files manually."))
                    if !model.batches.isEmpty {
                        Button(tr("Open recovery folder")) { revealRecovery(nil) }
                            .buttonStyle(.plain).font(Theme.caption.weight(.medium)).foregroundStyle(Theme.accent)
                    }
                }
            }
            InspectorPanel {
                if model.batches.isEmpty {
                    HStack(spacing: Theme.Space.m) {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(Theme.textTertiary).frame(width: 18)
                            .accessibilityHidden(true)
                        Text(tr("No recovery records. Reset data is moved here, not deleted, and can be restored."))
                            .font(Theme.secondary).foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, Theme.Space.m + 2).padding(.vertical, Theme.Space.m + 2)
                } else {
                    ForEach(Array(model.batches.enumerated()), id: \.element.id) { index, batch in
                        if index > 0 { InspectorDivider(inset: 44) }
                        batchRow(batch)
                    }
                }
            }
        }
    }

    func batchRow(_ batch: ClaudeResetBatch) -> some View {
        let restored = batch.entries.filter(\.restored).count
        let total = batch.entries.count
        let done = total > 0 && restored == total
        let bytes = batch.entries.reduce(Int64(0)) { $0 + $1.bytes }
        return HStack(alignment: .center, spacing: Theme.Space.m) {
            Image(systemName: done ? "checkmark.circle" : "archivebox").font(.system(size: 13))
                .foregroundStyle(done ? Theme.good : Theme.textTertiary).frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Space.s) {
                    Text(batch.created.formatted(date: .abbreviated, time: .shortened))
                        .font(Theme.rowTitle).foregroundStyle(Theme.textPrimary)
                    Text(batchStatus(restored: restored, total: total, bytes: bytes))
                        .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                }
                Text(batch.entries.map(\.target.title).joined(separator: ", "))
                    .font(Theme.secondary).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    .help(batch.id)
            }
            Spacer(minLength: Theme.Space.s)
            Button { revealRecovery(batch) } label: { Image(systemName: "folder").font(.system(size: 12)) }
                .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                .accessibilityLabel(tr("Reveal in Finder")).help(tr("Reveal in Finder"))
            Button(tr("Restore…")) { restoring = batch }
                .buttonStyle(PillButtonStyle()).controlSize(.small)
                .disabled(model.busy || done)
                .help(done ? tr("Everything in this record has been restored") : tr("Restore"))
        }
        .padding(.horizontal, Theme.Space.m + 2).padding(.vertical, Theme.Space.s + 2)
        .hoverHighlight()
    }

    func batchStatus(restored: Int, total: Int, bytes: Int64) -> String {
        let size = ByteFormat.string(bytes)
        if total > 0 && restored == total { return tr("%1$@ items · %2$@ · all restored", String(total), size) }
        if restored > 0 { return tr("%1$@ of %2$@ items restored · %3$@", String(restored), String(total), size) }
        return tr("%1$@ items · %2$@", String(total), size)
    }

    func revealRecovery(_ batch: ClaudeResetBatch?) {
        let cleanup = ClaudeCleanup()
        let url = batch.flatMap { cleanup.backupURL(batchID: $0.id) } ?? model.batches.first.flatMap { cleanup.backupURL(batchID: $0.id) }
        if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    // MARK: Action bar

    var actionBar: some View {
        let count = model.picked.count
        let open = available
        return ActionBar {
            SelectAllButton(available: open.count, selected: open.filter { model.picked($0.target) }.count,
                            selectAll: { model.pickAll(model.candidates) }, clear: { model.clear(model.candidates) })
                .disabled(model.busy || !model.loaded)
            Rectangle().fill(Theme.hairline).frame(width: 1, height: 22).padding(.horizontal, Theme.Space.xs)
            VStack(alignment: .leading, spacing: 1) {
                Text(count == 0 ? tr("Nothing selected") : tr("%1$@ selected · %2$@", String(count), ByteFormat.string(model.pickedBytes)))
                    .font(Theme.rowTitle.monospacedDigit()).foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())
                Text(tr("Moved to a private recovery folder; disk space is not freed."))
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer(minLength: Theme.Space.s)
            Button(tr("Review reset…")) {
                review = model.picked
                confirmation = ""
                confirming = true
            }
            .buttonStyle(PillButtonStyle(prominent: true))
            .disabled(model.busy || model.picked.isEmpty)
            .fixedSize()
        }
        .animation(Theme.quick, value: count)
    }
}

// MARK: - Confirmation sheets

struct ResetReviewItem {
    let target: ClaudeResetTarget
    let path: String
    let bytes: Int64
}

struct ClaudeResetConfirmation: View {
    let items: [ResetReviewItem]
    @Binding var confirmation: String
    let busy: Bool
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 22)).foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("Reset selected Claude data?")).font(.system(size: 17, weight: .bold))
                    Text(tr("%1$@ selected · %2$@", String(items.count), ByteFormat.string(items.reduce(0) { $0 + $1.bytes })))
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                InspectorPanel {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        if index > 0 { InspectorDivider(inset: 38) }
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: item.target.symbol).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                                .frame(width: 16).padding(.top, 2).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.target.title).font(.system(size: 13, weight: .semibold))
                                Text(item.target.impact).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(FS.tilde(item.path)).font(.system(size: 11).monospaced()).foregroundStyle(.white.opacity(0.5))
                                    .textSelection(.enabled)
                            }
                        }.padding(.horizontal, 12).padding(.vertical, 10)
                    }
                }
            }.frame(maxHeight: 240).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 7) {
                Text(tr("What happens")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                fact("tray.and.arrow.down", tr("Data is moved to a private recovery folder. Active Claude processes and changed paths are checked again before each move."))
                fact("clock.arrow.circlepath", tr("Restore it later from Recovery records on this page. The recovery folder still uses disk space."))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("Type RESET to continue")).font(.system(size: 12, weight: .semibold))
                TextField("RESET", text: $confirmation).textFieldStyle(.roundedBorder).font(.system(size: 13).monospaced())
                    .accessibilityLabel(tr("Type RESET to continue"))
            }
            HStack {
                Button(tr("Cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(tr("Reset selected"), role: .destructive, action: confirm)
                    .buttonStyle(PillButtonStyle(prominent: true, color: Color(red: 0.86, green: 0.25, blue: 0.24)))
                    .disabled(confirmation != "RESET" || busy)
            }
        }
        .padding(24).frame(width: 540)
        .background(Color(red: 0.09, green: 0.10, blue: 0.18))
        .preferredColorScheme(.dark)
    }

    func fact(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).frame(width: 16).accessibilityHidden(true)
            Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ClaudeRestoreConfirmation: View {
    let batch: ClaudeResetBatch
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 22)).foregroundStyle(.white.opacity(0.8))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("Restore Claude data?")).font(.system(size: 17, weight: .bold))
                    Text(batch.created.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            InspectorPanel {
                ForEach(Array(batch.entries.enumerated()), id: \.offset) { index, entry in
                    if index > 0 { InspectorDivider(inset: 38) }
                    HStack(spacing: 10) {
                        Image(systemName: entry.target.symbol).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                            .frame(width: 16).accessibilityHidden(true)
                        Text(entry.target.title).font(.system(size: 13))
                        Spacer()
                        Text(entry.restored ? tr("Restored") : ByteFormat.string(entry.bytes))
                            .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    }.padding(.horizontal, 12).padding(.vertical, 9)
                }
            }
            Text(tr("Quit Claude before restoring. New files at the original locations are kept; conflicting items will be skipped."))
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
            Text(batch.id).font(.system(size: 11).monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button(tr("Cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(tr("Restore"), action: confirm).buttonStyle(PillButtonStyle(prominent: true))
            }
        }
        .padding(24).frame(width: 500)
        .background(Color(red: 0.09, green: 0.10, blue: 0.18))
        .preferredColorScheme(.dark)
    }
}
