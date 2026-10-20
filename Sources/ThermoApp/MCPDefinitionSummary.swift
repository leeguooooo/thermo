import AgentDoctor
import SwiftUI
import ThermoL10n

struct MCPDefinitionSummaryPanel: View {
    @ObservedObject var store: MCPDefinitionStore
    let items: [AgentItem]
    let encoding: TextEncoding
    var busy = false
    @State private var scopeExpanded = false
    var body: some View {
        let summary = store.summary(items: items, encoding: encoding)
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "chart.bar.doc.horizontal").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                Text(tr("Inspected MCP definitions")).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary)
                InfoButton(text: tr("Configuration scanning does not connect to MCP servers. Connect & inspect measures definitions and connection timing. Analyze local logs below reads recorded tool calls.")
                           + "\n\n" + tr("Manual inspections in this window only; rescanning clears them. Counts are sums of separate configuration measurements, not an atomic snapshot or effective prompt usage. Shared servers configured in multiple hosts remain separate. Incomplete and uninspected configurations are not zero; definition findings do not establish task quality."),
                           title: tr("Inspection scope and measurement"))
                Spacer()
                if !store.entries.isEmpty {
                    Button(tr("Clear inspection measurements")) { store.reset() }
                        .buttonStyle(PillButtonStyle()).controlSize(.small).disabled(busy || !store.pending.isEmpty)
                }
            }
            Text(tr("%1$@ of %2$@ enabled configurations inspected completely · %3$@ incomplete · %4$@ running · %5$@ disabled", String(summary.completed), String(summary.configured), String(summary.incomplete), String(summary.running), String(summary.disabled)))
                .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
            if summary.completed > 0 {
                if summary.completed != summary.configured || summary.definitionTokens == nil || summary.instructionTokens == nil {
                    Text(tr("The full configured total is still unknown; some configurations or counts are missing."))
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
                Text(tr("Inspected subset: %1$@ tools · %2$@ definition bytes · definition-array counts sum ≈%3$@ tokens", String(summary.tools), String(summary.definitionBytes), summary.definitionTokens.map(String.init) ?? tr("Unknown")))
                    .font(Theme.mono).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                Text(tr("Separate server-instruction counts sum ≈%1$@ tokens · %2$@ tools with definition findings · %3$@ tool counts unavailable", summary.instructionTokens.map(String.init) ?? tr("Unknown"), String(summary.toolsWithIssues), String(summary.uncountedTools)))
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                DisclosureGroup(isExpanded: $scopeExpanded) {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        ForEach(summary.largest) { row in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.agent + " · " + row.server + " · " + row.tool.name).font(Theme.secondary).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                                Text(tr("Definition ≈%1$@ tokens · %2$@ bytes · %3$@ findings", row.tool.definition.tokenLabel, String(row.tool.definition.bytes), String(row.tool.issues.count)))
                                    .font(Theme.mono).foregroundStyle(Theme.textTertiary)
                                if let icons = row.tool.icons, let metadata = row.tool.metadata, icons.bytes > 0 || metadata.bytes > 0 {
                                    Text(tr("Icons JSON %1$@ bytes / ≈%2$@ tokens · _meta JSON %3$@ bytes / ≈%4$@ tokens",
                                            String(icons.bytes), icons.tokenLabel, String(metadata.bytes), metadata.tokenLabel))
                                        .font(Theme.mono).foregroundStyle(Theme.textTertiary)
                                }
                            }
                        }
                    }.padding(.top, Theme.Space.s).frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text(tr("Largest measured tool definitions across inspected configurations")).font(Theme.secondary.weight(.medium)).foregroundStyle(Theme.textSecondary)
                }
            } else {
                Text(tr("Overall definition size is unknown. Connect & inspect individual configurations to add measurements here."))
                    .font(Theme.secondary).foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(Theme.Space.l).glass()
    }
}
