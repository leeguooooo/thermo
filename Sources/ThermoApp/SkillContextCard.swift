import AgentDoctor
import SwiftUI
import ThermoL10n

/// Static footprint is kept separate from configuration health and runtime usage.
struct SkillContextCard: View {
    let items: [AgentItem]

    var ranked: [AgentItem] {
        var seen = Set<String>()
        return items.filter { $0.skillFootprint != nil && $0.skillFootprint?.scope != "cache" }.sorted {
            let a = $0.skillFootprint!.document.estimatedTokens
            let b = $1.skillFootprint!.document.estimatedTokens
            return a == b ? $0.id < $1.id : a > b
        }.filter { seen.insert($0.skillFootprint?.canonicalID ?? $0.id).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(tr("Skill footprint"), systemImage: "chart.bar.xaxis").font(.headline)
            Text(tr("Largest unique directory/plugin SKILL.md files · %1$@ files", String(ranked.count)))
                .font(.callout).foregroundStyle(.secondary)
            ForEach(SkillContextSummary.summarize(items), id: \.host) { summary in
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary.host).font(.subheadline.weight(.semibold))
                    Text(tr("%1$@ unique files · catalog ≈%2$@ tokens · documents ≈%3$@ tokens · %4$@ bytes", String(summary.uniqueFiles), String(summary.catalogEstimatedTokens), String(summary.documentEstimatedTokens), String(summary.documentBytes)))
                        .font(.caption.monospaced()).textSelection(.enabled)
                    Text(tr("%1$@ duplicate file entries excluded · cache inventory %2$@ files / %3$@ bytes, counted separately", String(summary.aliases), String(summary.cacheUniqueFiles), String(summary.cacheDocumentBytes)))
                        .font(.caption).foregroundStyle(.secondary)
                    if summary.inconsistentFiles > 0 || summary.unverifiedIdentityEntries > 0 {
                        Text(tr("%1$@ changing files and %2$@ entries with unknown identity were excluded from totals.", String(summary.inconsistentFiles), String(summary.unverifiedIdentityEntries)))
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            Text(tr("These are deduplicated inventory estimates, not effective session context. Same-name selection and actual loading are not inferred.")).font(.caption).foregroundStyle(.secondary)
            ForEach(Array(ranked.prefix(5))) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name + " · " + item.agent + (item.skillFootprint?.namespace.map { " · " + $0 } ?? "")).font(.subheadline.weight(.medium)).textSelection(.enabled)
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
