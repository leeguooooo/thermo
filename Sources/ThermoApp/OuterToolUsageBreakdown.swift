import AgentDoctor
import SwiftUI
import ThermoL10n

struct OuterToolUsageBreakdown: View {
    let report: ToolUsageReport
    @State private var visibleLimit = 8

    var body: some View {
        Group {
            if let rows = report.coverage.unattributedResults?.byTool {
                if !rows.isEmpty {
                    DisclosureGroup(tr("Outer tools ranked by observed returned text")) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(tr("Grouped only by logged outer tool names. These are the same observations as the outer aggregate, not additional usage. Commands and nested CLI/MCP ownership are not inferred."))
                                .font(.caption).foregroundStyle(.secondary)
                            if (report.coverage.unattributedResults?.unmeasuredResults ?? 0) > 0 {
                                Text(tr("Some returned content was not measured; this ranks measured text only."))
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            Text(tr("Showing %1$@ of %2$@ entries", String(min(visibleLimit, rows.count)), String(rows.count)))
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(Array(rows.prefix(visibleLimit))) { row in
                                rowView(row)
                            }
                            if visibleLimit < rows.count {
                                Button(tr("Show more outer tools")) { visibleLimit = min(rows.count, visibleLimit + 8) }
                                    .accessibilityLabel(tr("Show more outer tools"))
                                    .accessibilityIdentifier("toolUsage.outer.showMore")
                            }
                            Text(ToolUsageReport.errorStatusExplanation).font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 8)
                    }
                }
            } else {
                Text(tr("Per-tool outer rankings were not measured in this report; analyze again."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: report.generated) { _ in visibleLimit = 8 }
    }

    private func seconds(_ value: Double?) -> String {
        value.map { String(format: "%.3f s", $0) } ?? tr("Unknown")
    }

    private func rowView(_ row: ToolUsageRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text((row.name == "Unidentified outer tool" ? tr("Unidentified outer tool") : row.name) + " · " + row.host)
                .font(.subheadline.weight(.medium)).textSelection(.enabled)
            Text(tr("%1$@ calls · %2$@ results · %3$@ explicit result errors · %4$@ unknown error status · %5$@ missing results",
                    String(row.calls), String(row.completed), String(row.reportedErrors), String(row.unknownErrorStatus), String(row.missingResults)))
                .font(.caption)
            Text(tr("Returned text %1$@ bytes / ≈%2$@ tokens · median %3$@ · P95 %4$@ · observed sum %5$@",
                    String(row.returnedTextBytes), String(row.returnedTextEstimatedTokens),
                    seconds(row.medianSeconds), seconds(row.p95Seconds), seconds(row.totalObservedSeconds)))
                .font(.caption.monospaced())
                .help(tr("P95 is shown only with at least 20 valid timing samples."))
            if let encoding = row.referenceEncoding {
                Text(tr("%1$@ reference text tokens: %2$@ · %3$@ results unavailable", encoding,
                        row.referenceReturnedTextTokens.map(String.init) ?? tr("Unknown"), String(row.unavailableReferenceResults ?? 0)))
                    .font(.caption.monospaced())
            }
            if let rate = row.explicitErrorRate, let denominator = row.knownStatusResults {
                Text(tr("Explicit errors among known-status results: %1$@ / %2$@ (%3$@)",
                        String(row.reportedErrors), String(denominator), String(format: "%.1f%%", rate * 100)))
                    .font(.caption)
            } else {
                Text(tr("Explicit error rate unknown; no usable known-status denominator."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let percentage = report.outerReturnedTextSummary?.percentage(of: row) {
                Text(tr("Share of observed outer returned-text tokens: %1$@", String(format: "%.1f%%", percentage)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ResultTextRepresentationNotice(row: row)
            Text(tr("%1$@ results include unmeasured content; %2$@ non-text blocks were not tokenized.",
                    row.unmeasuredResults.map(String.init) ?? tr("Unknown"), String(row.nonTextBlocks)))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
