import AgentDoctor
import SwiftUI
import ThermoL10n

struct MCPBatchInspectButton: View {
    @ObservedObject var model: MCPBatchInspectionModel
    @ObservedObject var store: MCPDefinitionStore
    let items: [AgentItem]
    let encoding: TextEncoding
    let busy: Bool
    @State private var showing = false
    @State private var host = ""
    @State private var selected = Set<String>()
    @State private var timeout: Double = 10
    @State private var protocolMode: MCPInspectionProtocol = .handshake
    private var eligible: [AgentItem] {
        var seen = Set<String>()
        return items.filter { $0.area == .mcp && $0.enabled && seen.insert($0.id).inserted }
            .sorted { ($0.agent, $0.name, $0.id) < ($1.agent, $1.name, $1.id) }
    }
    private var visible: [AgentItem] { eligible.filter { host.isEmpty || $0.agent == host } }
    private var chosen: [AgentItem] { visible.filter { selected.contains($0.id) } }
    private var locked: Bool { model.running || busy }

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Button(model.running ? tr("View batch progress…") : tr("Select MCP configurations & inspect…")) { showing = true }
                .buttonStyle(PillButtonStyle()).controlSize(.small)
                .disabled((busy && !model.running) || (!store.pending.isEmpty && !model.running) || eligible.isEmpty)
            if model.running { ProgressView().controlSize(.small) }
            Group {
                if model.running {
                    Text(model.stopping ? tr("Stopping batch inspection…") : tr("Batch checks returned: %1$@ / %2$@", String(model.rows.count), String(model.total)))
                } else if model.reason != nil { progress }
            }
            .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 0)
        }
        .sheet(isPresented: $showing) { sheet }
        .onDisappear { model.cancel() }
    }

    var sheet: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(tr("Inspect selected MCP configurations")).font(Theme.heading).foregroundStyle(Theme.textPrimary)
                InfoButton(text: tr("Starts selected configured services sequentially and reads definitions. No business tools are called. The total inspection budget is 120 seconds; cleanup can finish slightly later. Selection does not prove a host currently loads these configurations."))
                Spacer()
            }
            HStack(spacing: Theme.Space.m) {
                Picker(tr("Host"), selection: $host) {
                    Text(tr("All hosts")).tag("")
                    ForEach(Array(Set(eligible.map(\.agent))).sorted(), id: \.self) { Text($0).tag($0) }
                }.onChange(of: host) { _ in selected = [] }
                Picker(tr("Per-configuration limit"), selection: $timeout) {
                    ForEach([10.0, 30.0, 60.0, 120.0], id: \.self) { value in
                        Text(tr("%1$@ seconds", String(Int(value)))).tag(value)
                    }
                }
                Picker(tr("Inspection protocol"), selection: $protocolMode) {
                    ForEach(MCPInspectionProtocol.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                }
            }
            .font(Theme.secondary).controlSize(.small).disabled(locked)
            if model.running || model.reason != nil {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    progress
                    if let current = model.current { Text(tr("Checking: %1$@", current)).lineLimit(2).help(current) }
                }
                .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    SelectAllButton(available: visible.count, selected: chosen.count,
                                    selectAll: { selected = Set(visible.map(\.id)) }, clear: { selected = [] })
                        .disabled(locked)
                    Spacer()
                }
                .padding(.horizontal, Theme.Space.m + 2).padding(.vertical, Theme.Space.s + 2)
                InspectorDivider(inset: 0)
                ScrollView {
                    // Lazy placement cycles in this sheet when it opens or reopens with results.
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { InspectorDivider(inset: 50) }
                            row(item)
                        }
                        if !model.rows.isEmpty {
                            InspectorDivider(inset: 0)
                            Text(tr("Latest batch results")).font(Theme.sectionTitle).foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, Theme.Space.m + 2).padding(.top, Theme.Space.m)
                            ForEach(model.rows, id: \.displayID) { row in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.agent + " · " + row.name + " · " + state(row))
                                        .font(Theme.caption).foregroundStyle(row.complete ? Theme.textSecondary : Theme.caution)
                                    if !row.complete, !row.message.isEmpty {
                                        Text(row.message).font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(3)
                                            .help(row.message).textSelection(.enabled)
                                    }
                                }
                                .padding(.horizontal, Theme.Space.m + 2).padding(.vertical, Theme.Space.xs)
                            }
                            Spacer().frame(height: Theme.Space.s)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .glass()
            HStack(spacing: Theme.Space.s) {
                Button(tr("Close")) { model.cancel(); showing = false }.keyboardShortcut(.cancelAction)
                    .buttonStyle(PillButtonStyle())
                Spacer()
                if model.running {
                    Button(tr("Stop checking")) { model.cancel() }.disabled(model.stopping).buttonStyle(PillButtonStyle())
                }
                Button(tr("Inspect selected")) { model.start(items: chosen, encoding: encoding, timeout: timeout, protocolMode: protocolMode) }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .disabled(locked || !store.pending.isEmpty || chosen.isEmpty)
            }
        }
        .padding(Theme.Space.xl).frame(width: 640, height: 560)
        .background(Theme.canvas)
        .preferredColorScheme(.dark)
        .onDisappear { model.cancel() }
    }

    func row(_ item: AgentItem) -> some View {
        let on = selected.contains(item.id)
        return HStack(alignment: .center, spacing: Theme.Space.m) {
            SelectToggle(selected: on, label: item.agent + " · " + item.name) {
                if on { selected.remove(item.id) } else { selected.insert(item.id) }
            }
            .disabled(locked)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Space.s) {
                    Text(item.name).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1).help(item.name)
                    StatusTag(text: item.agent)
                }
                Text(item.source ?? item.detail).font(Theme.mono).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.m + 2).padding(.vertical, Theme.Space.s)
        .contentShape(Rectangle())
        .onTapGesture { if !locked { if on { selected.remove(item.id) } else { selected.insert(item.id) } } }
        .hoverHighlight()
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.reason != nil { Text(tr("Latest batch results")).fontWeight(.semibold) }
            Text(tr("%1$@ checks returned · %2$@ complete · %3$@ incomplete · %4$@ not started", String(model.rows.count), String(model.rows.filter(\.complete).count), String(model.rows.filter { !$0.complete }.count), String(model.notStarted)))
            if let reason = model.reason {
                Text(reason == .cancelled ? tr("Batch inspection cancelled") : reason == .budgetExpired ? tr("Batch time budget reached") : tr("Selected checks returned"))
            }
        }
    }
    private func state(_ row: MCPBatchInspectionModel.Row) -> String {
        if row.complete { return tr("Definitions inspected") }
        switch row.state {
        case .cancelled: return tr("Inspection cancelled.")
        case .timedOut: return tr("Inspection timed out.")
        case .authenticationRequired: return tr("Authentication required")
        case .disabled: return tr("Disabled")
        case .unsupported: return tr("Unsupported")
        default: return tr("Inspection incomplete")
        }
    }
}
