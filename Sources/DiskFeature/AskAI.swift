import LocalAIUI
import ThermoUI
import NativeFeatureAPI
import SwiftUI
import AppKit
import CleanKit
import ThermoL10n

/// "AI pick" on a cleanup page: the local AI judges every item and ticks the ones it calls safe
/// to delete. It never cleans; the first time it shows exactly what will be sent.
struct AIPickButton: View {
    @ObservedObject var model: DiskModel
    let category: CleanCategory
    @ObservedObject private var store = LocalAIStore.shared
    @State private var preview: LocalAICleanQuestion?

    var body: some View {
        let busy = model.aiPicking == category
        Button {
            guard model.acceptsWork, let backend = store.backend else { return }
            if store.consented { model.aiPick(category, using: backend) } else { preview = model.aiQuestion(category) }
        } label: {
            HStack(spacing: 4) {
                if busy { ProgressView().controlSize(.mini) } else { Image(systemName: "sparkles") }
                Text(busy ? tr("AI is picking…") : tr("AI pick"))
            }
        }
        .buttonStyle(PillButtonStyle()).controlSize(.small)
        .disabled(!model.acceptsWork || store.backend == nil || model.report == nil || model.scanning || model.cleaning || model.aiPicking != nil
                  || model.aiQuestion(category).items.isEmpty)
        .help(store.backend.map { tr("Ask %1$@ to tick what is safe to delete. Nothing is cleaned until you press Clean.", $0.label) }
              ?? tr("No AI found on this Mac (magpie, Ollama, LM Studio or Claude Code)."))
        .onAppear {if model.acceptsWork {store.discover()}}
        .sheet(item: Binding(get: { preview.map(PreviewBox.init) }, set: { preview = $0?.question })) { box in
            consent(box.question)
        }
    }

    struct PreviewBox: Identifiable { let question: LocalAICleanQuestion; var id: String { question.category } }

    func consent(_ q: LocalAICleanQuestion) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(tr("Let AI pick what to clean?")).font(Theme.heading).foregroundStyle(Theme.textPrimary)
            Text(tr("Only these facts are sent, never file contents. The AI may pass them to the cloud model it uses."))
                .font(Theme.secondary).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(q.facts).font(Theme.mono).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            .padding(Theme.Space.s)
            .background(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).fill(Theme.surface))
            Text(tr("It only ticks items it calls safe to delete. Risky and protected items are never ticked, and nothing is removed until you press Clean."))
                .font(Theme.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(tr("Cancel")) { preview = nil }.keyboardShortcut(.cancelAction)
                Button(tr("Send")) {
                    guard model.acceptsWork else{return}
                    store.consented = true; preview = nil
                    if let backend = store.backend { model.aiPick(category, using: backend) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.xl).frame(width: 560)
    }
}

/// What the AI did on this page: still thinking, what it ticked, or why it could not answer.
struct AIPickBanner: View {
    @ObservedObject var model: DiskModel
    let category: CleanCategory

    var body: some View {
        if model.aiPicking == category {
            NoticeBanner(text: tr("AI is reading the list and picking what is safe to delete…"), busy: true)
        } else if let error = model.aiError {
            Label(tr("AI could not pick: %1$@", error), systemImage: "exclamationmark.triangle")
                .font(Theme.secondary).foregroundStyle(Theme.caution).frame(maxWidth: .infinity, alignment: .leading)
        } else if let picked = model.aiPicked[category] {
            let items = (model.report?.items ?? []).filter { picked.contains($0.id) }
            VStack(alignment: .leading, spacing: 4) {
                Label(picked.isEmpty ? tr("AI found nothing it is sure can go. Its reason is under each item.")
                      : tr("AI ticked %1$@ items, %2$@. Items it was unsure about are left unticked; its reason is under each item.",
                           String(picked.count), ByteFormat.string(items.reduce(0) { $0 + $1.bytes })),
                      systemImage: "sparkles")
                    .font(Theme.secondary).foregroundStyle(Theme.textPrimary)
                if let summary = model.aiSummaries[category], !summary.isEmpty {
                    Text(summary).font(Theme.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                Text(tr("AI can be wrong. Look over the ticks before you press Clean."))
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
            .padding(Theme.Space.m).frame(maxWidth: .infinity, alignment: .leading).glass()
        }
    }
}
