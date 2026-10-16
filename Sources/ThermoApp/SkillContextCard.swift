import AgentDoctor
import SwiftUI
import ThermoL10n

/// Static footprint is kept separate from configuration health and runtime usage.
struct SkillContextCard: View {
    let items: [AgentItem]

    var ranked: [AgentItem] {
        var seen = Set<String>()
        return items.filter { $0.skillFootprint != nil && $0.skillFootprint?.scope != "cache" }.sorted {
            let a = $0.skillFootprint!.document.comparisonTokens ?? -1
            let b = $1.skillFootprint!.document.comparisonTokens ?? -1
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
                    if let encoding = summary.referenceEncoding {
                        Text(tr("%1$@ reference counts · catalog %2$@ · documents %3$@ · %4$@ files unavailable", encoding, summary.referenceCatalogTokens.map(String.init) ?? tr("Unknown"), summary.referenceDocumentTokens.map(String.init) ?? tr("Unknown"), String(summary.unavailableReferenceFiles ?? 0)))
                            .font(.caption.monospaced()).textSelection(.enabled)
                    }
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
                        if let error = footprint.document.referenceError { Text(tr("Reference count unavailable: %1$@", error)).font(.caption).foregroundStyle(.secondary) }
                    }
                    if let source = item.skillFootprint?.sourcePath { Text(source).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }
            }
            let qualities = items.compactMap { $0.skillFootprint?.quality }
            let checked = qualities.reduce(0) { $0 + $1.checkedLocalReferences }
            let issues = qualities.reduce(0) { $0 + $1.issues.count }
            if qualities.isEmpty {
                Text(tr("Skill content evidence has not been collected.")).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(tr("Content checks: %1$@ local references checked · %2$@ findings · %3$@ incomplete inspections", String(checked), String(issues), String(qualities.filter { !$0.complete }.count)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(tr("Reference checks only test current local targets; generated files and intentional copies need review. No quality score or automatic removal is inferred."))
                .font(.caption).foregroundStyle(.secondary)
            Text(SkillFootprint.coverage).font(.caption).foregroundStyle(.secondary)
            Text(SkillFootprint.caveat).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(18).glass()
    }
}
