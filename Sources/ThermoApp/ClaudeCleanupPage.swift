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

struct ClaudeCleanupPage: View {
    @ObservedObject var model: ClaudeCleanupModel
    @State private var tab = 0
    @State private var review: [ClaudeResetCandidate] = []
    @State private var confirming = false
    @State private var confirmation = ""
    @State private var restoring: ClaudeResetBatch?

    init(model: ClaudeCleanupModel, initialTab: Int = 0) {
        self.model = model
        self._tab = State(initialValue: initialTab)
    }

    var body: some View {
        WindowPage(title: tr("Claude cleanup"), subtitle: tr("Review local Claude data, browser privacy and network settings.")) {
            Picker(tr("Tools"), selection: $tab) {
                Text(tr("Claude reset")).tag(0)
                Text(tr("Privacy & network")).tag(1)
            }.pickerStyle(.segmented)
            if tab == 0 { resetContent } else { PrivacyToolsView(model: model.privacy) }
        }
        .onAppear { if !model.loaded { model.scan() } }
        .sheet(isPresented: $confirming) { confirmationSheet }
        .sheet(item: $restoring) { batch in
            VStack(alignment: .leading, spacing: 16) {
                Text(tr("Restore Claude data?")).font(.title2.bold())
                Text(tr("Quit Claude before restoring. New files at the original locations are kept; conflicting items will be skipped."))
                Text(batch.id).font(.caption.monospaced()).textSelection(.enabled)
                HStack {
                    Button(tr("Cancel")) { restoring = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(tr("Restore")) { restoring = nil; model.restore(batch) }
                        .buttonStyle(PillButtonStyle(prominent: true))
                }
            }.padding(24).frame(width: 520).preferredColorScheme(.dark)
        }
    }

    var resetContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(tr("Resetting local state can sign you out or remove local history. Nothing is selected automatically."), systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.orange).padding(16).glass()
            HStack {
                Text(tr("Known locations only; project folders are kept.")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button(tr("Scan again")) { model.scan() }.disabled(model.busy)
            }
            ForEach(model.candidates, id: \.target) { candidate in
                candidateRow(candidate)
            }
            HStack {
                Text(tr("%1$@ selected", String(model.picked.count))).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(tr("Review reset")) {
                    review = model.picked
                    confirmation = ""
                    confirming = true
                }.buttonStyle(PillButtonStyle(prominent: true)).disabled(model.busy || model.picked.isEmpty)
            }
            Text(tr("Reset data stays in a private recovery folder and still uses disk space. Restore it here before removing any recovery files manually."))
                .font(.caption).foregroundStyle(.secondary)
            if let outcome = model.outcome {
                Text(outcome).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(16).glass()
            }
            if !model.batches.isEmpty {
                Text(tr("Recovery records")).font(.headline)
                ForEach(model.batches, id: \.id) { batch in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(batch.created, style: .date)
                            Text(batch.id).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button(tr("Reveal in Finder")) {
                            if let url = ClaudeCleanup().backupURL(batchID: batch.id) {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                        }
                        Button(tr("Restore")) { restoring = batch }.disabled(model.busy)
                    }.padding(14).glass()
                }
            }
        }
    }

    func candidateRow(_ candidate: ClaudeResetCandidate) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle(candidate.target.title, isOn: Binding(
                get: { model.selected.contains(candidate.target) },
                set: { _ in model.toggle(candidate) }
            )).labelsHidden().toggleStyle(.checkbox)
                .disabled(model.busy || candidate.status != .available)
                .accessibilityLabel(candidate.target.title)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(candidate.target.title).font(.headline)
                    Spacer()
                    Text(candidate.status == .missing ? tr("Not found") : ByteFormat.string(candidate.bytes))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(candidate.target.impact).font(.callout).foregroundStyle(.secondary)
                Text(FS.tilde(candidate.path)).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                if let reason = candidate.reason {
                    Label(tr(reason), systemImage: "lock.fill").font(.caption).foregroundStyle(.orange)
                }
            }
        }.padding(16).glass()
    }

    var confirmationSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("Reset selected Claude data?")).font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(review, id: \.target) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.target.title).font(.headline)
                            Text(item.target.impact).font(.callout).foregroundStyle(.secondary)
                            Text(FS.tilde(item.path)).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 280)
            Text(tr("Data is moved to a private recovery folder. Active Claude processes and changed paths are checked again before each move.")).font(.callout)
            Text(tr("Type RESET to continue")).font(.callout)
            TextField("RESET", text: $confirmation).textFieldStyle(.roundedBorder)
            HStack {
                Button(tr("Cancel")) { confirming = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(tr("Reset selected"), role: .destructive) {
                    let plan = review
                    confirming = false
                    model.reset(plan)
                }.disabled(confirmation != "RESET" || model.busy)
            }
        }.padding(24).frame(width: 560).preferredColorScheme(.dark)
    }
}
