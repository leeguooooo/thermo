import AgentDoctor
import SwiftUI
import ThermoL10n

@MainActor
final class MCPInspectionModel: ObservableObject {
    @Published var report: MCPInspection?
    @Published var running = false
    private var cancellation: DoctorCancellation?

    func inspect(_ item: AgentItem, encoding: TextEncoding = .heuristic, timeout: TimeInterval = 10,
                 protocolMode: MCPInspectionProtocol = .handshake,
                 completion: (@MainActor (MCPInspection) -> Void)? = nil) {
        guard !running else { return }
        let cancellation = DoctorCancellation()
        self.cancellation = cancellation
        report = nil
        running = true
        Task.detached(priority: .userInitiated) {
            let result = AgentDoctor.inspectMCP(item.id, timeout: timeout,
                                               protocolMode: protocolMode,
                                               env: DoctorEnvironment(tokenEncoding: encoding, cancelled: { cancellation.isCancelled }))
            await MainActor.run {
                guard self.cancellation === cancellation else { return }
                self.report = result
                completion?(result)
                self.running = false
                self.cancellation = nil
            }
        }
    }
    func cancel() { cancellation?.cancel() }
}

struct MCPInspectButton: View {
    let item: AgentItem
    var busy: Bool
    var encoding: TextEncoding = .heuristic
    let store: MCPDefinitionStore
    @State private var timeout: Double = 10
    @State private var protocolMode: MCPInspectionProtocol = .handshake
    @State private var showing = false
    @StateObject private var model = MCPInspectionModel()

    var body: some View {
        Button(tr("Connect & inspect")) { showing = true; start() }
            .buttonStyle(PillButtonStyle()).controlSize(.small)
            .disabled(busy || !item.enabled)
            .help(tr("Starts the configured stdio server or connects to its HTTP endpoint and reads tool definitions. No business tools are called."))
            .sheet(isPresented: $showing) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(item.name).font(Theme.heading).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true).help(item.name).textSelection(.enabled)
                    Text(tr("Starts the configured stdio server or connects to its HTTP endpoint and reads tool definitions. No business tools are called."))
                        .font(Theme.secondary).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                    Text(item.detail).font(Theme.mono).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    Picker(tr("Connection budget"), selection: $timeout) {
                        ForEach([10.0, 30.0, 60.0, 120.0], id: \.self) { value in
                            Text(tr("%1$@ seconds", String(Int(value)))).tag(value)
                        }
                    }.disabled(model.running)
                    Picker(tr("Inspection protocol"), selection: $protocolMode) {
                        ForEach(MCPInspectionProtocol.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }.disabled(model.running)
                    if let report = model.report { MCPInspectionResultView(report: report) }
                    else if model.running { ProgressView(tr("Inspecting MCP definitions…")) }
                    HStack(spacing: Theme.Space.s) {
                        Button(tr("Close")) { model.cancel(); showing = false }.keyboardShortcut(.cancelAction)
                            .buttonStyle(PillButtonStyle())
                        Spacer()
                        if model.running { Button(tr("Stop checking")) { model.cancel() }.buttonStyle(PillButtonStyle()) }
                        Button(tr("Check Again")) { start() }.buttonStyle(PillButtonStyle(prominent: true)).disabled(model.running)
                    }
                }
                .padding(Theme.Space.xl).frame(width: 640)
                .background(Theme.canvas).preferredColorScheme(.dark)
                .onDisappear { model.cancel() }
            }
    }
    @MainActor private func start() {
        guard !model.running else { return }
        let ticket = store.begin(item.id)
        model.inspect(item, encoding: encoding, timeout: timeout, protocolMode: protocolMode) { report in
            store.accept(report, id: item.id, encoding: encoding, ticket: ticket)
        }
    }
}

struct MCPInspectionResultView: View {
    let report: MCPInspection
    func seconds(_ value: Double?) -> String { value.map { String(format: "%.3f s", $0) } ?? tr("Not measured") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(report.complete ? tr("Definitions inspected") : tr("Inspection incomplete"),
                      systemImage: report.complete ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(Theme.secondary.weight(.semibold))
                Text(report.message).font(Theme.secondary).textSelection(.enabled)
                if let encoding = report.referenceEncoding { Text(tr("Ordinary-text reference encoding: %1$@", encoding)).font(Theme.caption).foregroundStyle(Theme.textTertiary) }
                Text(report.generated, style: .time).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                Text(tr("Total connection inspection time: %1$@", seconds(report.elapsedSeconds))).font(Theme.mono)
                if let discovery = report.discoverySeconds {
                    Text(tr("Discovery %1$@ · list %2$@", seconds(discovery), seconds(report.listingSeconds)))
                        .font(Theme.mono)
                } else if report.transport == "streamable-http" {
                    Text(tr("HTTP handshake %1$@ · list %2$@", seconds(report.handshakeSeconds), seconds(report.listingSeconds)))
                        .font(Theme.mono)
                } else {
                    Text(tr("Start %1$@ · handshake %2$@ · list %3$@", seconds(report.startupSeconds), seconds(report.handshakeSeconds), seconds(report.listingSeconds)))
                        .font(Theme.mono)
                }
                if let analysis = report.analysisSeconds { Text(tr("Local definition analysis: %1$@", seconds(analysis))).font(Theme.caption).foregroundStyle(Theme.textTertiary) }
                if let error = report.definitions?.referenceError { Text(tr("Reference count unavailable: %1$@", error)).font(Theme.caption).foregroundStyle(Theme.textTertiary) }
                if let definitions = report.definitions {
                    Text(tr("%1$@ tools · definitions ≈%2$@ tokens · %3$@ bytes", String(report.tools.count), definitions.tokenLabel, String(definitions.bytes)))
                        .font(Theme.rowTitle)
                }
                if let instructions = report.instructions {
                    Text(tr("Server instructions ≈%1$@ tokens", instructions.tokenLabel)).font(Theme.caption)
                }
                if !report.tools.isEmpty { Text(MCPToolFootprint.metadataNote).font(Theme.caption).foregroundStyle(Theme.textTertiary) }
                ForEach(Array(report.tools.enumerated()), id: \.offset) { _, tool in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tool.name).font(Theme.rowTitle).textSelection(.enabled)
                        Text(tr("Definition ≈%1$@ · description ≈%2$@ · input schema ≈%3$@ · output schema ≈%4$@ tokens",
                                tool.definition.tokenLabel, tool.description.tokenLabel, tool.inputSchema.tokenLabel, tool.outputSchema.tokenLabel))
                            .font(Theme.mono).textSelection(.enabled)
                        if let icons = tool.icons, let metadata = tool.metadata {
                            Text(tr("Icons JSON %1$@ bytes / ≈%2$@ tokens · _meta JSON %3$@ bytes / ≈%4$@ tokens",
                                    String(icons.bytes), icons.tokenLabel, String(metadata.bytes), metadata.tokenLabel))
                                .font(Theme.mono).foregroundStyle(Theme.textTertiary)
                        } else {
                            Text(tr("Icon and _meta counts were not measured in this report.")).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        }
                        ForEach(Array(tool.issues.enumerated()), id: \.offset) { _, issue in
                            Text(issue).font(Theme.caption).foregroundStyle(Theme.caution).textSelection(.enabled)
                        }
                    }
                }
                if report.transport == "streamable-http", let cleanup = report.cleanupStatus {
                    Text(cleanup == "closed" ? tr("HTTP inspection session closed") : cleanup == "not_needed" ? tr("No HTTP session was created") : cleanup == "server_retained" ? tr("Server does not support explicit session closure") : tr("HTTP session closure was not confirmed"))
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    if let details = report.cleanupDetails, details.reason != "notNeeded" {
                        Text(details.summary).font(Theme.caption).foregroundStyle(Theme.textTertiary).textSelection(.enabled)
                    }
                }
                Text(report.measurementNote).font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 180, idealHeight: 350, maxHeight: 350)
    }
}
