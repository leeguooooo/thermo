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
            Picker(tr("Tools"), selection: $tab) {
                Text(tr("Claude reset")).tag(0)
                Text(tr("Privacy & network")).tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .padding(.bottom, 2)
            if tab == 0 { resetContent } else { PrivacyToolsView(model: model.privacy) }
        }
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

    var resetContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            summary
            Label(tr("Resetting local state can sign you out or remove local history. Nothing is selected automatically."), systemImage: "exclamationmark.triangle")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.65)).padding(.horizontal, 4)
                .fixedSize(horizontal: false, vertical: true)
            if let outcome = model.outcome {
                NoticeBanner(text: outcome) { model.outcome = nil }
            }
            ForEach(Array(ResetGroup.allCases.enumerated()), id: \.offset) { _, group in
                let rows = group.targets.compactMap { target in model.candidates.first { $0.target == target } }
                if !rows.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionHeader(title: group.title)
                        InspectorPanel {
                            ForEach(Array(rows.enumerated()), id: \.element.target) { index, candidate in
                                if index > 0 { InspectorDivider() }
                                candidateRow(candidate)
                            }
                        }
                    }
                }
            }
            Text(tr("Known locations only; project folders are kept."))
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).padding(.horizontal, 4)
            recovery.padding(.top, 8)
        }
    }

    var summary: some View {
        InspectorPanel {
            HStack(alignment: .center, spacing: 0) {
                stat(model.loaded ? (model.partiallyMeasured ? "≥ " : "") + ByteFormat.string(model.localBytes) : "—",
                     model.partiallyMeasured ? tr("Measured local data") : tr("Local data"))
                statDivider
                stat(model.loaded ? String(model.candidates.filter { $0.status == .available }.count) : "—", tr("Can reset"))
                statDivider
                stat(model.loaded ? String(model.blocked.count) : "—", tr("Locked"), warning: !model.blocked.isEmpty)
                Spacer(minLength: 8)
                if model.busy { ProgressView().controlSize(.small).padding(.trailing, 8) }
                Button { model.scan() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.8))
                .disabled(model.busy)
                .accessibilityLabel(tr("Scan again"))
                .help(tr("Scan again"))
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            if let lock = lockExplanation {
                InspectorDivider(inset: 16)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(.orange).accessibilityHidden(true)
                    (Text(lock.reason).fontWeight(.semibold).foregroundColor(.white.opacity(0.9)) + Text("  ") + Text(lock.fix).foregroundColor(.white.opacity(0.6)))
                        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .padding(.horizontal, 16).padding(.vertical, 9)
            }
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

    func stat(_ value: String, _ label: String, warning: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 17, weight: .semibold).monospacedDigit())
                .foregroundStyle(warning ? Color.orange : .white)
            Text(label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
        }
        .accessibilityElement(children: .combine)
        .frame(minWidth: 64, alignment: .leading)
    }

    var statDivider: some View {
        Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1, height: 28).padding(.horizontal, 16)
    }

    func candidateRow(_ candidate: ClaudeResetCandidate) -> some View {
        let target = candidate.target
        let open = expanded.contains(target)
        let missing = candidate.status == .missing
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Toggle(target.title, isOn: Binding(
                    get: { model.selected.contains(target) },
                    set: { _ in model.toggle(candidate) }
                )).labelsHidden().toggleStyle(.checkbox)
                    .disabled(model.busy || candidate.status != .available)
                    .accessibilityLabel(target.title)
                    .accessibilityHint(target.impact)
                    .padding(.top, 1)
                Image(systemName: target.symbol).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    .frame(width: 16).padding(.top, 2).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(target.shortTitle).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Text(target.brief).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    if candidate.status == .blocked {
                        Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(.orange)
                            .accessibilityLabel(tr("Locked"))
                            .accessibilityHint(candidate.reason.map { tr($0) } ?? "")
                            .help(candidate.reason.map { tr($0) } ?? tr("Locked"))
                    }
                    Text(missing ? tr("Not found") : candidate.snapshot == nil ? "—" : ByteFormat.string(candidate.bytes))
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(.white.opacity(missing ? 0.4 : 0.7))
                        .fixedSize()
                    Button { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { if open { expanded.remove(target) } else { expanded.insert(target) } } } label: {
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 18, height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.45))
                    .accessibilityLabel(open ? tr("Hide details") : tr("Show details"))
                    .accessibilityHint(target.title)
                }.padding(.top, 1)
            }
            if open {
                VStack(alignment: .leading, spacing: 5) {
                    Text(target.impact).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                    if let note = target.alternativeNote {
                        Text(note).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(FS.tilde(candidate.path)).font(.system(size: 11).monospaced()).foregroundStyle(.white.opacity(0.6))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if let reason = candidate.reason {
                        Label(tr(reason), systemImage: "lock.fill").font(.system(size: 11)).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.leading, 52).padding(.top, 8)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .opacity(missing ? 0.6 : 1)
    }

    // MARK: Recovery

    var recovery: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: tr("Recovery records")) {
                if !model.batches.isEmpty {
                    Button(tr("Open recovery folder")) { revealRecovery(nil) }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                }
            }
            InspectorPanel {
                if model.batches.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(.white.opacity(0.4)).frame(width: 18)
                            .accessibilityHidden(true)
                        Text(tr("No recovery records. Reset data is moved here, not deleted, and can be restored."))
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }.padding(.horizontal, 14).padding(.vertical, 14)
                } else {
                    ForEach(Array(model.batches.enumerated()), id: \.element.id) { index, batch in
                        if index > 0 { InspectorDivider() }
                        batchRow(batch)
                    }
                }
            }
            Text(tr("Reset data stays in a private recovery folder and still uses disk space. Restore it here before removing any recovery files manually."))
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).padding(.horizontal, 4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func batchRow(_ batch: ClaudeResetBatch) -> some View {
        let restored = batch.entries.filter(\.restored).count
        let total = batch.entries.count
        let done = total > 0 && restored == total
        let bytes = batch.entries.reduce(Int64(0)) { $0 + $1.bytes }
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: done ? "checkmark.circle" : "archivebox").font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.5)).frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(batch.created.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text(batchStatus(restored: restored, total: total, bytes: bytes))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                Text(batch.entries.map(\.target.title).joined(separator: ", "))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4)).lineLimit(2)
                    .help(batch.id)
            }
            Spacer(minLength: 8)
            Button { revealRecovery(batch) } label: { Image(systemName: "folder") }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6))
                .accessibilityLabel(tr("Reveal in Finder")).help(tr("Reveal in Finder"))
            Button(tr("Restore…")) { restoring = batch }
                .buttonStyle(PillButtonStyle())
                .disabled(model.busy || done)
                .help(done ? tr("Everything in this record has been restored") : tr("Restore"))
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
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
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(count == 0 ? tr("Nothing selected") : tr("%1$@ selected · %2$@", String(count), ByteFormat.string(model.pickedBytes)))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                Text(tr("Moved to a private recovery folder; disk space is not freed."))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(tr("Review reset…")) {
                review = model.picked
                confirmation = ""
                confirming = true
            }
            .buttonStyle(PillButtonStyle(prominent: true))
            .disabled(model.busy || model.picked.isEmpty)
            .fixedSize()
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 32).padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(
            Color(red: 0.07, green: 0.09, blue: 0.18)
                .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1) }
                .ignoresSafeArea()
        )
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
