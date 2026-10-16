import AgentDoctor
import SwiftUI
import ThermoL10n

/// Static footprint is kept separate from configuration health and runtime usage.
struct SkillContextCard: View {
    let items: [AgentItem]

    var ranked: [AgentItem] {
        items.filter { $0.skillFootprint != nil }.sorted {
            let a = $0.skillFootprint!.document.estimatedTokens
            let b = $1.skillFootprint!.document.estimatedTokens
            return a == b ? $0.id < $1.id : a > b
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(tr("Skill footprint"), systemImage: "chart.bar.xaxis").font(.headline)
            Text(tr("Largest inspected SKILL.md files · %1$@ measured entries", String(ranked.count)))
                .font(.callout).foregroundStyle(.secondary)
            ForEach(Array(ranked.prefix(5))) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name + " · " + item.agent).font(.subheadline.weight(.medium)).textSelection(.enabled)
                    if let footprint = item.skillFootprint {
                        Text(footprint.summary).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    if let source = item.skillFootprint?.sourcePath { Text(source).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }
            }
            Text(SkillFootprint.coverage).font(.caption).foregroundStyle(.secondary)
            Text(SkillFootprint.caveat).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(18).glass()
    }
}
