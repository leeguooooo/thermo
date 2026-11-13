import AgentCore
import CleanKit
import Darwin
import Foundation
import MCP
import ModuleKit
import ThermoKit

/// The SDK owns JSON-RPC framing, negotiation and cancellation. Only validated module calls reach
/// an isolated CLI child; the child's output never shares the MCP transport's stdout.
enum ModuleMCPServer {
    static func run() -> Never {
        Task.detached {
            do { try await serve(); fflush(stdout); exit(0) }
            catch { FileHandle.standardError.write(Data("thermo MCP: \(error)\n".utf8)); exit(1) }
        }
        dispatchMain()
    }
    static func serve() async throws {
        let server = Server(name:"thermo",version:ThermoVersion.string,
            instructions:"Tools follow the modules enabled in Thermo Settings. Review dry-run results before explicitly confirming a change. Never retry an uncertain mutation; inspect operation history first.",
            capabilities:.init(tools:.init(listChanged:true)),configuration:.strict)
        let state = ModuleMCPState()
        await server.onNotification(InitializedNotification.self) { _ in await state.didInitialize() }
        await server.withMethodHandler(ListTools.self) { _ in .init(tools:try await state.tools()) }
        await server.withMethodHandler(CallTool.self) { params in try await state.call(params) }
        let changes = Task {
            while !Task.isCancelled {
                if (try? await state.takeListChange()) == true {
                    try? await server.notify(ToolListChangedNotification.message())
                }
                try? await Task.sleep(nanoseconds:1_000_000_000)
            }
        }
        defer { changes.cancel() }
        try await server.start(transport:StdioTransport())
        await server.waitUntilCompleted()
        // A disconnected client does not restart or silently abandon an in-flight change.
        await state.drain()
        await server.stop()
    }
}

actor ModuleMCPState {
    private var active = Set<String>()
    private var initialized = false
    private var lastReported: Data?
    private let readCatalog: @Sendable () throws -> ModuleCommandCatalog
    init(readCatalog: @escaping @Sendable () throws -> ModuleCommandCatalog = { try ModuleCLI.catalog() }) {
        self.readCatalog = readCatalog
    }
    func didInitialize() { initialized = true }
    private func currentTools() throws -> [MCP.Tool] {
        try readCatalog().entries.map { try JSONDecoder().decode(MCP.Tool.self,from:JSONEncoder().encode($0.tool)) }
    }
    private func fingerprint(_ tools: [MCP.Tool]) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(tools)
    }
    func tools() throws -> [MCP.Tool] {
        let result = try currentTools()
        lastReported = try fingerprint(result)
        return result
    }
    func takeListChange() throws -> Bool {
        guard initialized else { return false }
        let current = try fingerprint(currentTools())
        defer { lastReported = current }
        return lastReported.map { $0 != current } ?? false
    }
    func drain() async {
        while !active.isEmpty { try? await Task.sleep(nanoseconds:50_000_000) }
    }
    func call(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let entry = try readCatalog().tool(named:params.name) else { throw MCPError.invalidParams("The module is switched off or this tool is unavailable.") }
        let arguments: [String:ModuleArgument]
        do { arguments = try JSONDecoder().decode([String:ModuleArgument].self,from:JSONEncoder().encode(params.arguments ?? [:]));try entry.validate(arguments) }
        catch { throw MCPError.invalidParams(String(describing:error)) }
        guard active.insert(entry.moduleID).inserted else { return .init(content:[.text("Another command is running in this module. No action started.")],isError:true) }
        defer { active.remove(entry.moduleID) }
        var values = arguments
        if entry.command.parameters.contains(where:{$0.name == "json" && $0.kind == .boolean && $0.repeats != true}),values["json"] == nil,values["csv"] != .boolean(true) { values["json"] = .boolean(true) }
        let request = ModuleCLI.Invocation(tool:entry.toolName,arguments:values)
        let data = try JSONEncoder().encode(request)
        guard data.count <= 65536 else { throw MCPError.invalidParams("Module arguments exceed 64 KiB.") }
        let cancellable = !entry.command.mutates || values["dry-run"] == .boolean(true)
        let cancellation = ScanCancellation()
        try Task.checkCancellation()
        let result = try await withTaskCancellationHandler {
            try await Task.detached(priority:.utility) {
                let input = try Self.privateInput(data)
                defer { try? input.close() }
                guard let executable = Bundle.main.executableURL?.path else { throw CLIError("Cannot locate this CLI executable.") }
                return CommandRunner.run(executable,arguments:["--module-tool-request"],timeout:Double.greatestFiniteMagnitude,
                    outputLimit:4*1024*1024,input:input,separateError:true,cancelled:{ cancellable && cancellation.isCancelled })
            }.value
        } onCancel: { cancellation.cancel(reason:"user") }
        var text = result.output
        if result.status != 0, !result.errorOutput.isEmpty { text += "\n" + result.errorOutput }
        if result.cancelled { text += "\nRead-only command cancelled." }
        if result.truncated { text += "\nOutput exceeded 4 MiB. The command may have completed; inspect history before another change." }
        if result.status != 0 { text += "\nCLI exit status: \(result.status). No operation was automatically retried." }
        let isError = result.status != 0 || result.cancelled || result.truncated || result.timedOut
        var structured: Value?
        if !isError,let value = try? JSONDecoder().decode(Value.self,from:Data(result.output.utf8)),case .object = value { structured = value }
        return .init(content:[.text(text)],structuredContent:structured,isError:isError)
    }
    /// Unlink a private input file immediately; only the child stdin descriptor receives its data.
    nonisolated static func privateInput(_ data: Data) throws -> FileHandle {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-module-input-"+UUID().uuidString).path
        let fd = open(path,O_CREAT|O_EXCL|O_RDWR|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd >= 0 else { throw CLIError("Cannot create private module input.") }
        guard unlink(path) == 0 else { close(fd);throw CLIError("Cannot retire private module input.") }
        let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        do { try handle.write(contentsOf:data);try handle.seek(toOffset:0);return handle }
        catch { try? handle.close();throw error }
    }
}
