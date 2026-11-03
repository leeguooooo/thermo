import SwiftUI
import AppKit
import CleanKit
import ThermoL10n

/// Finds the local AI once per launch; the "Ask AI" button only appears when one answers.
@MainActor final class LocalAIStore: ObservableObject {
    static let shared = LocalAIStore()
    @Published private(set) var backend: LocalAIBackend?
    private var looking: Task<Void, Never>?
    private var looked = false

    func discover(force: Bool = false) {
        guard looking == nil, force || !looked else { return }
        looking = Task {
            let found = await LocalAI.discover()
            backend = found; looked = true; looking = nil
        }
    }

    var consented: Bool {
        get { UserDefaults.standard.bool(forKey: "localAI.consented") }
        set { UserDefaults.standard.set(newValue, forKey: "localAI.consented"); objectWillChange.send() }
    }
}

/// When Thermo is unsure: ask the AI on this Mac for a second opinion. Advice only.
struct AskAIPanel: View {
    /// Built on the first tap: it may list a folder on disk.
    let make: () -> LocalAIQuestion
    @ObservedObject private var store = LocalAIStore.shared
    @State private var phase: Phase = .idle
    @State private var built: LocalAIQuestion?

    init(_ make: @escaping () -> LocalAIQuestion) { self.make = make }
    init(question: LocalAIQuestion) { self.make = { question } }

    var question: LocalAIQuestion { built ?? make() }

    enum Phase: Equatable { case idle, preview, asking, answered(LocalAIAnswer), failed(String) }

    var body: some View {
        Group {
            if let backend = store.backend {
                content(backend)
            }
        }
        .onAppear { store.discover() }
    }

    @ViewBuilder func content(_ backend: LocalAIBackend) -> some View {
        switch phase {
        case .idle:
            Button { built = make(); if store.consented { ask(backend) } else { phase = .preview } } label: {
                Label(tr("Ask AI"), systemImage: "sparkles")
            }
            .buttonStyle(PillButtonStyle()).controlSize(.small)
            .help(tr("Ask %1$@ whether this can go", backend.label))
        case .preview:
            card {
                Text(tr("Sent to %1$@", backend.label)).font(Theme.sectionTitle).foregroundStyle(Theme.textSecondary)
                Text(question.facts).font(Theme.mono).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(tr("Only these facts are sent, never file contents. The AI may pass them to the cloud model it uses."))
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(tr("Send")) { store.consented = true; ask(backend) }.buttonStyle(PillButtonStyle(prominent: true))
                    Button(tr("Cancel")) { phase = .idle }.buttonStyle(PillButtonStyle())
                }
            }
        case .asking:
            HStack(spacing: Theme.Space.s) {
                ProgressView().controlSize(.small)
                Text(tr("Asking %1$@…", backend.label)).font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
        case .answered(let a):
            card {
                HStack(spacing: Theme.Space.s) {
                    let (text, color) = Self.verdict(a.verdict)
                    Text(text).font(Theme.label).foregroundStyle(color)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(color.opacity(0.15)))
                    Text(tr("AI answer · %1$@", a.source)).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
                Text(a.reason).font(Theme.secondary).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let how = a.how {
                    HStack(alignment: .top) {
                        Text(how).font(Theme.mono).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(how, forType: .string) } label: {
                            Image(systemName: "doc.on.doc")
                        }.buttonStyle(.borderless).help(tr("Copy"))
                    }
                }
                if let blocked = question.blocked {
                    Text(tr("Thermo still won't remove it: %1$@", blocked)).font(Theme.caption).foregroundStyle(Theme.caution)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(tr("AI can be wrong. Nothing is ticked or removed for you."))
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
            }
        case .failed(let why):
            HStack(spacing: Theme.Space.s) {
                Text(why).font(Theme.caption).foregroundStyle(Theme.caution).lineLimit(3)
                Button(tr("Try again")) { store.discover(force: true); phase = .idle }.buttonStyle(.borderless).font(Theme.caption)
            }
        }
    }

    func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s, content: c)
            .padding(Theme.Space.m).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).fill(Theme.surface))
    }

    func ask(_ backend: LocalAIBackend) {
        phase = .asking
        Task {
            do { phase = .answered(try await LocalAI.ask(question, using: backend)) }
            catch { phase = .failed(error.localizedDescription) }
        }
    }

    static func verdict(_ v: LocalAIAnswer.Verdict) -> (String, Color) {
        switch v {
        case .delete: return (tr("Can delete"), Theme.good)
        case .careful: return (tr("Check first"), Theme.caution)
        case .keep: return (tr("Keep"), Theme.danger)
        }
    }
}

/// The 空间透视 context menu opens this for one row.
struct AskAISheet: View {
    let question: LocalAIQuestion
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.m) {
                if let p = question.path {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: p)).resizable().frame(width: 32, height: 32).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(question.title).font(Theme.heading).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if let p = question.path {
                        Text(FSPath.tilde(p)).font(Theme.mono).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
                if let b = question.bytes { Text(ByteFormat.string(b)).font(Theme.figure(.metric)).foregroundStyle(Theme.textPrimary) }
            }
            AskAIPanel(question: question)
            HStack { Spacer(); Button(tr("Done"), action: close).keyboardShortcut(.defaultAction) }
        }
        .padding(Theme.Space.xl)
        .frame(width: 520)
    }
}
