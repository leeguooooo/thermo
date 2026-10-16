import AgentDoctor
import SwiftUI
import ThermoL10n

struct MCPDefinitionSummaryPanel: View {
    @ObservedObject var store: MCPDefinitionStore
    let items: [AgentItem]
    let encoding: TextEncoding
    var body: some View {
        let summary = store.summary(items: items, encoding: encoding)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(tr("Inspected MCP definitions"), systemImage: "chart.bar.doc.horizontal").font(.headline)
                Spacer()
                if !store.entries.isEmpty { Button(tr("Clear inspection measurements")) { store.reset() }.disabled(!store.pending.isEmpty) }
            }
            Text(tr("%1$@ of %2$@ enabled configurations inspected completely · %3$@ incomplete · %4$@ running · %5$@ disabled", String(summary.completed), String(summary.configured), String(summary.incomplete), String(summary.running), String(summary.disabled)))
                .font(.caption).textSelection(.enabled)
            if summary.completed > 0 {
                if summary.completed != summary.configured || summary.definitionTokens == nil || summary.instructionTokens == nil {
                    Text(tr("The full configured total is still unknown; some configurations or counts are missing."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(tr("Inspected subset: %1$@ tools · %2$@ definition bytes · definition-array counts sum ≈%3$@ tokens", String(summary.tools), String(summary.definitionBytes), summary.definitionTokens.map(String.init) ?? tr("Unknown")))
                    .font(.callout.monospaced()).textSelection(.enabled)
                Text(tr("Separate server-instruction counts sum ≈%1$@ tokens · %2$@ tools with definition findings · %3$@ tool counts unavailable", summary.instructionTokens.map(String.init) ?? tr("Unknown"), String(summary.toolsWithIssues), String(summary.uncountedTools)))
                    .font(.caption).foregroundStyle(.secondary)
                Text(tr("Largest measured tool definitions across inspected configurations")).font(.subheadline.bold())
                ForEach(summary.largest) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.agent + " · " + row.server + " · " + row.tool.name).font(.caption).textSelection(.enabled)
                        Text(tr("Definition ≈%1$@ tokens · %2$@ bytes · %3$@ findings", row.tool.definition.tokenLabel, String(row.tool.definition.bytes), String(row.tool.issues.count)))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(tr("Overall definition size is unknown. Connect & inspect individual configurations to add measurements here."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text(tr("Manual inspections in this window only; rescanning clears them. Counts are sums of separate configuration measurements, not an atomic snapshot or effective prompt usage. Shared servers configured in multiple hosts remain separate. Incomplete and uninspected configurations are not zero; definition findings do not establish task quality."))
                .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18).glass()
    }
}
