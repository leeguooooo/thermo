import AgentDoctor
import SwiftUI
import ThermoL10n

@MainActor
final class MCPInspectionModel: ObservableObject {
    @Published var report: MCPInspection?
    @Published var running = false
    private var cancellation: DoctorCancellation?

    func inspect(_ item: AgentItem) {
        guard !running else { return }
        let cancellation = DoctorCancellation()
        self.cancellation = cancellation
        report = nil
        running = true
        Task.detached(priority: .userInitiated) {
            let result = AgentDoctor.inspectMCP(item.id, timeout: 10,
                                               env: DoctorEnvironment(cancelled: { cancellation.isCancelled }))
            await MainActor.run {
                guard self.cancellation === cancellation else { return }
                self.report = result
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
    @State private var showing = false
    @StateObject private var model = MCPInspectionModel()

    var body: some View {
        Button(tr("Connect & inspect")) { showing = true; model.inspect(item) }
            .disabled(busy || !item.enabled)
            .help(tr("Starts the configured stdio server or connects to its HTTP endpoint and reads tool definitions. No business tools are called."))
            .sheet(isPresented: $showing) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(item.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Text(tr("Starts the configured stdio server or connects to its HTTP endpoint and reads tool definitions. No business tools are called."))
                        .font(.callout).foregroundStyle(.secondary)
                    Text(item.detail).font(.caption.monospaced()).textSelection(.enabled)
                    if let report = model.report { MCPInspectionResultView(report: report) }
                    else if model.running { ProgressView(tr("Inspecting MCP definitions…")) }
                    HStack {
                        Button(tr("Check Again")) { model.inspect(item) }.disabled(model.running)
                        if model.running { Button(tr("Stop checking")) { model.cancel() } }
                        Spacer()
                        Button(tr("Close")) { model.cancel(); showing = false }.keyboardShortcut(.cancelAction)
                    }
                }
                .padding(24).frame(width: 640)
                .onDisappear { model.cancel() }
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
                    .font(.headline)
                Text(report.message).font(.callout).textSelection(.enabled)
                Text(report.generated, style: .time).font(.caption).foregroundStyle(.secondary)
                if report.transport == "streamable-http" {
                    Text(tr("HTTP handshake %1$@ · list %2$@", seconds(report.handshakeSeconds), seconds(report.listingSeconds)))
                        .font(.caption.monospaced())
                } else {
                    Text(tr("Start %1$@ · handshake %2$@ · list %3$@", seconds(report.startupSeconds), seconds(report.handshakeSeconds), seconds(report.listingSeconds)))
                        .font(.caption.monospaced())
                }
                if let definitions = report.definitions {
                    Text(tr("%1$@ tools · definitions ≈%2$@ tokens · %3$@ bytes", String(report.tools.count), String(definitions.estimatedTokens), String(definitions.bytes)))
                        .font(.subheadline.weight(.medium))
                }
                if let instructions = report.instructions {
                    Text(tr("Server instructions ≈%1$@ tokens", String(instructions.estimatedTokens))).font(.caption)
                }
                ForEach(Array(report.tools.enumerated()), id: \.offset) { _, tool in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tool.name).font(.subheadline.weight(.medium)).textSelection(.enabled)
                        Text(tr("Definition ≈%1$@ · description ≈%2$@ · input schema ≈%3$@ · output schema ≈%4$@ tokens",
                                String(tool.definition.estimatedTokens), String(tool.description.estimatedTokens), String(tool.inputSchema.estimatedTokens), String(tool.outputSchema.estimatedTokens)))
                            .font(.caption.monospaced()).textSelection(.enabled)
                        ForEach(Array(tool.issues.enumerated()), id: \.offset) { _, issue in
                            Text(issue).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                        }
                    }
                }
                if report.transport == "streamable-http", let cleanup = report.cleanupStatus {
                    Text(cleanup == "closed" ? tr("HTTP inspection session closed") : cleanup == "not_needed" ? tr("No HTTP session was created") : cleanup == "server_retained" ? tr("Server does not support explicit session closure") : tr("HTTP session closure was not confirmed"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(report.measurementNote).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 350)
    }
}
