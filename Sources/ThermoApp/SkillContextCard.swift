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

    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(Theme.standard.unlessReduced(reduceMotion)) { expanded.toggle() } } label: {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "chart.bar.xaxis").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                    Text(tr("Skill footprint")).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary)
                    Text(tr("Largest unique directory/plugin SKILL.md files · %1$@ files", String(ranked.count)))
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    Spacer(minLength: Theme.Space.s)
                    InfoButton(text: tr("These are deduplicated inventory estimates, not effective session context. Same-name selection and actual loading are not inferred."))
                    DisclosureChevron(expanded: expanded)
                }
                .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ForEach(SkillContextSummary.summarize(items), id: \.host) { summary in
                InspectorDivider(inset: Theme.Space.l)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.host).font(Theme.secondary.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                    Text(tr("%1$@ unique files · catalog ≈%2$@ tokens · documents ≈%3$@ tokens · %4$@ bytes", String(summary.uniqueFiles), summary.catalogEstimatedTokens.map(String.init) ?? tr("Unknown"), String(summary.documentEstimatedTokens), String(summary.documentBytes)))
                        .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                    if expanded {
                        if let encoding = summary.referenceEncoding {
                            Text(tr("%1$@ reference counts · catalog %2$@ · documents %3$@ · %4$@ files unavailable", encoding, summary.referenceCatalogTokens.map(String.init) ?? tr("Unknown"), summary.referenceDocumentTokens.map(String.init) ?? tr("Unknown"), String(summary.unavailableReferenceFiles ?? 0)))
                                .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                            Text(tr("Heuristic comparison")).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        }
                        Text(tr("%1$@ duplicate file entries excluded · cache inventory %2$@ files / %3$@ bytes, counted separately", String(summary.aliases), String(summary.cacheUniqueFiles), String(summary.cacheDocumentBytes)))
                            .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    }
                    if summary.inconsistentFiles > 0 || summary.unverifiedIdentityEntries > 0 {
                        Text(tr("%1$@ changing files and %2$@ entries with unknown identity were excluded from totals.", String(summary.inconsistentFiles), String(summary.unverifiedIdentityEntries)))
                            .font(Theme.caption).foregroundStyle(Theme.caution)
                    }
                }
                .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s + 2)
            }
            if expanded {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    ForEach(Array(ranked.prefix(5))) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name + " · " + item.agent + (item.skillFootprint?.namespace.map { " · " + $0 } ?? ""))
                                .font(Theme.secondary.weight(.medium)).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                            if let footprint = item.skillFootprint {
                                Text(footprint.summary).font(Theme.mono).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                                if let error = footprint.catalog.referenceError { Text(tr(error)).font(Theme.caption).foregroundStyle(Theme.textTertiary) }
                                if let error = footprint.document.referenceError { Text(tr("Reference count unavailable: %1$@", error)).font(Theme.caption).foregroundStyle(Theme.textTertiary) }
                            }
                            if let source = item.skillFootprint?.sourcePath {
                                Text(source).font(Theme.mono).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            }
                        }
                    }
                    let contentSummaries = SkillQualitySummary.summarize(items)
                    if contentSummaries.isEmpty {
                        Text(tr("Skill content evidence has not been collected.")).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    } else {
                        ForEach(Array(contentSummaries.enumerated()), id: \.offset) { _, summary in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(summary.host + " · " + (summary.scope == "cache" ? tr("Cache inventory · loading unverified") : tr("Directory and configured plugin files")))
                                    .font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                                Text(tr("Content evidence: %1$@ / %2$@ unique files inspected · %3$@ alias entries excluded", String(summary.inspectedFiles), String(summary.uniqueFiles), String(summary.aliases)))
                                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                                Text(tr("Content checks: %1$@ local references checked · %2$@ findings · %3$@ incomplete inspections", String(summary.checkedLocalReferences), String(summary.findings), String(summary.incompleteInspections)))
                                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                                if summary.unavailableFiles + summary.conflictingFiles + summary.unverifiedIdentityEntries + summary.unmeasuredEntries > 0 {
                                    Text(tr("Excluded from content totals: %1$@ files without evidence · %2$@ conflicting files · %3$@ entries with unknown identity · %4$@ unmeasured entries", String(summary.unavailableFiles), String(summary.conflictingFiles), String(summary.unverifiedIdentityEntries), String(summary.unmeasuredEntries)))
                                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text(tr("Coverage and counting method")).font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                        Text(tr("Reference checks only test current local targets; generated files and intentional copies need review. No quality score or automatic removal is inferred."))
                        Text(SkillFootprint.coverage)
                        Text(SkillFootprint.caveat)
                    }
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
                .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).glass()
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
}
