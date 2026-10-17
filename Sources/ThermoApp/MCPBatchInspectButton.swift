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
    private var eligible: [AgentItem] {
        var seen = Set<String>()
        return items.filter { $0.area == .mcp && $0.enabled && seen.insert($0.id).inserted }
            .sorted { ($0.agent, $0.name, $0.id) < ($1.agent, $1.name, $1.id) }
    }
    private var visible: [AgentItem] { eligible.filter { host.isEmpty || $0.agent == host } }
    private var chosen: [AgentItem] { visible.filter { selected.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(model.running ? tr("View batch progress…") : tr("Select MCP configurations & inspect…")) { showing = true }
                    .disabled((busy && !model.running) || (!store.pending.isEmpty && !model.running) || eligible.isEmpty)
                if model.running { ProgressView().controlSize(.small) }
            }
            if model.running {
                Text(model.stopping ? tr("Stopping batch inspection…") : tr("Batch checks returned: %1$@ / %2$@", String(model.rows.count), String(model.total)))
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.reason != nil { progress.font(.caption).foregroundStyle(.secondary) }
        }
        .sheet(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 12) {
                Text(tr("Inspect selected MCP configurations")).font(.title2.bold())
                Text(tr("Starts selected configured services sequentially and reads definitions. No business tools are called. The total inspection budget is 120 seconds; cleanup can finish slightly later. Selection does not prove a host currently loads these configurations."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Picker(tr("Host"), selection: $host) {
                        Text(tr("All hosts")).tag("")
                        ForEach(Array(Set(eligible.map(\.agent))).sorted(), id: \.self) { Text($0).tag($0) }
                    }.onChange(of: host) { _ in selected = [] }
                    Picker(tr("Per-configuration limit"), selection: $timeout) {
                        ForEach([10.0, 30.0, 60.0, 120.0], id: \.self) { value in
                            Text(tr("%1$@ seconds", String(Int(value)))).tag(value)
                        }
                    }
                }.disabled(model.running || busy)
                HStack {
                    Button(tr("Select visible")) { selected = Set(visible.map(\.id)) }
                    Button(tr("Clear selection")) { selected = [] }
                    Spacer()
                    Text(tr("%1$@ selected", String(chosen.count))).font(.caption)
                }.disabled(model.running || busy)
                if model.running || model.reason != nil {
                    progress.font(.caption)
                    if let current = model.current { Text(tr("Checking: %1$@", current)).font(.caption).lineLimit(2).help(current) }
                }
                ScrollView {
                    // Lazy placement cycles in this sheet when it opens or reopens with results.
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(visible) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Toggle(isOn: Binding(get: { selected.contains(item.id) }, set: { value in
                                    if value { selected.insert(item.id) } else { selected.remove(item.id) }
                                })) {
                                    Text(item.agent + " · " + item.name).lineLimit(2).help(item.name)
                                }.toggleStyle(.checkbox).disabled(model.running || busy)
                                Text(item.source ?? item.detail).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        if !model.rows.isEmpty {
                            Divider()
                            Text(tr("Latest batch results")).font(.headline)
                            ForEach(model.rows, id: \.displayID) { row in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(row.agent + " · " + row.name + " · " + state(row))
                                        .font(.caption).foregroundStyle(row.complete ? Color.secondary : Color.orange)
                                    if !row.complete, !row.message.isEmpty {
                                        Text(row.message).font(.caption).foregroundStyle(.secondary).lineLimit(3).help(row.message).textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button(tr("Inspect selected")) { model.start(items: chosen, encoding: encoding, timeout: timeout) }
                        .disabled(model.running || busy || !store.pending.isEmpty || chosen.isEmpty)
                    if model.running { Button(tr("Stop checking")) { model.cancel() }.disabled(model.stopping) }
                    Spacer()
                    Button(tr("Close")) { model.cancel(); showing = false }.keyboardShortcut(.cancelAction)
                }
            }.padding(24).frame(width: 640, height: 560)
            .onDisappear { model.cancel() }
        }
        .onDisappear { model.cancel() }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 4) {
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
