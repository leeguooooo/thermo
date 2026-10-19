import Foundation
import Darwin
import ThermoL10n

public struct MCPToolFootprint: Codable, Sendable {
    public var name: String
    public var description: TextFootprint
    public var inputSchema: TextFootprint
    public var outputSchema: TextFootprint
    public var annotations: TextFootprint
    public var definition: TextFootprint
    public var issues: [String]
    /// Serialized directory metadata only; absent in older reports means unmeasured.
    public var icons: TextFootprint? = nil
    public var metadata: TextFootprint? = nil

    public static var metadataNote: String {
        tr("Icon and _meta counters measure serialized directory text, not image tokens. Component views are not additive and do not prove model prompt usage.")
    }
}

/// Sanitized cleanup evidence: never includes endpoint URLs, session IDs or error bodies.
public struct MCPCleanupDetails: Codable, Equatable, Sendable {
    public var reason: String
    public var httpStatusCode: Int?
    public var elapsedSeconds: Double
    public var budgetSeconds: Double

    public var summary: String {
        let label: String
        switch reason {
        case "closed": label = tr("Session closure acknowledged")
        case "notNeeded": label = tr("No cleanup request was needed")
        case "unsupported": label = tr("Explicit session closure is unsupported")
        case "httpError": label = tr("Session closure returned an HTTP error")
        case "timedOut": label = tr("Session closure was not confirmed before the time limit")
        case "transportError": label = tr("Session closure transport failed")
        case "authenticationRequired": label = tr("Session closure requires authentication; no login attempted")
        case "invalidRequest": label = tr("Session closure request could not be constructed")
        case "responseMissing": label = tr("Session closure ended without an HTTP response")
        default: label = tr("Unknown")
        }
        return tr("Cleanup: %1$@ · HTTP %2$@ · observed %3$@ s · budget %4$@ s", label,
                  httpStatusCode.map(String.init) ?? tr("Unknown"),
                  String(format: "%.3f", elapsedSeconds), String(format: "%.3f", budgetSeconds))
    }
}

public struct MCPInspection: Codable, Sendable {
    public enum State: String, Codable, Sendable {
        case ready, failed, timedOut, cancelled, unsupported, disabled, authenticationRequired
    }
    public var generated: Date
    public var name: String
    public var agent: String
    public var state: State = .failed
    public var message = ""
    public var referenceEncoding: String?
    public var referenceEngine: String? = nil
    public var transport: String?
    public var cleanupStatus: String?
    public var cleanupDetails: MCPCleanupDetails? = nil
    public var protocolVersion: String?
    public var startupSeconds: Double?
    public var handshakeSeconds: Double?
    public var listingSeconds: Double?
    public var analysisSeconds: Double?
    public var elapsedSeconds: Double = 0
    public var complete = false
    public var instructions: TextFootprint?
    public var definitions: TextFootprint?
    public var tools: [MCPToolFootprint] = []
    public var measurementNote = tr("Heuristic definition fields use ascii4-unicode1-v1; optional reference counts use the named ordinary-text encoding. Neither proves actual prompt framing or billed usage. Full definitions may differ from agent loading. Output schema is a definition, not returned content. No business tools were called.")
}

extension AgentDoctor {
    /// Explicit active inspection only. `context` and `run` never call this API.
    /// Matching by item id disambiguates agents, projects and plugin scopes.
    public static func inspectMCP(_ name: String, agent: String? = nil, timeout: TimeInterval = 10,
                                  env: DoctorEnvironment = DoctorEnvironment()) -> MCPInspection {
        var checks = ConfigChecks(env: env)
        checks.runAll(includeSkills: false)
        if env.cancelled() {
            return MCPInspection(generated: env.now, name: Redact.text(name), agent: agent ?? "",
                                 state: .cancelled, message: tr("Inspection cancelled."))
        }
        let matches = checks.servers.filter { server in
            let id = Redact.identifier("mcp|\(server.agent)|\(server.source)|\(server.project ?? "")|\(server.name)")
            return (server.name == name || id == name) && (agent == nil || agent == server.agent)
        }
        guard matches.count == 1, let server = matches.first else {
            return MCPInspection(generated: env.now, name: Redact.text(name), agent: agent ?? "",
                                 message: matches.isEmpty ? "No matching MCP configuration." : "Multiple configurations match; select an exact item id from agents list mcp.")
        }
        return MCPInspector.inspect(server, env: env, timeout: timeout)
    }
}

enum MCPInspector {
    struct Failure: Error {
        var state: MCPInspection.State = .failed
        var message: String
    }
    static func clock() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
    static func json(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }

    static func footprint(_ tool: [String: Any], encoding: TextEncoding = .heuristic) throws -> MCPToolFootprint {
        func measure(_ text: String) -> TextFootprint { TextFootprint(text, encoding: encoding) }
        guard let name = tool["name"] as? String, !name.isEmpty else { throw Failure(message: tr("Tool entry has no valid name.")) }
        var issues: [String] = []
        let description = tool["description"] as? String ?? ""
        if description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append(tr("Tool description is missing or empty.")) }
        func schema(_ key: String, required: Bool) throws -> TextFootprint {
            guard let value = tool[key] else {
                if required { issues.append(tr("Input schema is missing.")) }
                return measure("")
            }
            if let object = value as? [String: Any] {
                if object["type"] as? String != "object" { issues.append(tr("%1$@ must declare object type.", key)) }
                if let unresolved = MCPLocalSchemaReferences.unresolvedCount(in: object), unresolved > 0 {
                    issues.append(tr("Unresolved local schema references in %1$@: %2$@.", key, String(unresolved)))
                }
            } else { issues.append(tr("%1$@ is not a JSON object.", key)) }
            return measure(try json(value))
        }
        let input = try schema("inputSchema", required: true)
        let output = try schema("outputSchema", required: false)
        return MCPToolFootprint(name: Redact.text(String(name.prefix(500))), description: measure(description),
                                inputSchema: input, outputSchema: output,
                                annotations: measure(try tool["annotations"].map(json) ?? ""),
                                definition: measure(try json(tool)), issues: issues,
                                icons: measure(try tool["icons"].map(json) ?? ""),
                                metadata: measure(try tool["_meta"].map(json) ?? ""))
    }

    static func inspect(_ server: MCPServer, env: DoctorEnvironment, timeout: TimeInterval) -> MCPInspection {
        let started = clock()
        var report = MCPInspection(generated: env.now, name: Redact.text(server.name), agent: server.agent)
        report.referenceEncoding = env.tokenEncoding == .heuristic ? nil : env.tokenEncoding.rawValue
        report.referenceEngine = env.tokenEncoding == .heuristic ? nil : ReferenceTokenizer.engine
        func finish() -> MCPInspection {
            report.elapsedSeconds = max(0, clock() - started)
            if report.state == .authenticationRequired, server.command == nil {
                report.measurementNote = tr("This HTTP inspection uses a separate connection and configured credentials; it does not automatically load host-managed OAuth. Authentication here does not establish the host connection state. No login or business tool calls were attempted.")
            }
            return report
        }
        guard timeout.isFinite, timeout > 0, timeout <= 120 else { report.message = tr("Timeout must be between 0 and 120 seconds."); return finish() }
        guard !server.disabled else { report.state = .disabled; report.message = tr("Server is disabled; no connection attempted."); return finish() }
        guard !env.cancelled() else { report.state = .cancelled; report.message = tr("Inspection cancelled."); return finish() }
        do {
            let transport: MCPTransport
            if let command = server.command {
                var lookup = env
                if let path = server.env["PATH"] { lookup.path = env.expand(path).components(separatedBy: ":").filter { !$0.isEmpty } }
                guard let executable = lookup.resolve(env.expand(command)) else { throw Failure(message: tr("Configured executable could not be resolved.")) }
                transport = try MCPStdio(executable: executable, server: server, env: env, deadline: started + timeout)
                report.transport = "stdio"
                report.startupSeconds = clock() - started
            } else {
                transport = try MCPHTTP(server: server, env: env, deadline: started + timeout)
                report.transport = "streamable-http"
                // HTTP has no child process startup; connection setup is part of handshake.
            }
            defer {
                transport.close()
                report.cleanupStatus = transport.cleanupStatus
                report.cleanupDetails = transport.cleanupDetails
            }
            let handshake = clock()
            let initialized = try transport.request("initialize", params: [
                "protocolVersion": "2025-06-18", "capabilities": [String: Any](),
                "clientInfo": ["name": "thermo-inspector", "version": "1"],
            ])
            guard let version = initialized["protocolVersion"] as? String,
                  let capabilities = initialized["capabilities"] as? [String: Any],
                  let info = initialized["serverInfo"] as? [String: Any],
                  info["name"] is String, info["version"] is String,
                  initialized["instructions"] == nil || initialized["instructions"] is String,
                  capabilities["tools"] == nil || capabilities["tools"] is [String: Any] else { throw Failure(message: tr("Invalid initialization result.")) }
            guard ["2024-11-05", "2025-03-26", "2025-06-18"].contains(version) else {
                throw Failure(state: .unsupported, message: tr("Server selected an unsupported protocol version."))
            }
            report.protocolVersion = version
            transport.negotiated(version)
            try transport.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
            report.handshakeSeconds = clock() - handshake
            let listing = clock()
            var tools: [[String: Any]] = []
            if capabilities["tools"] != nil {
                var cursor: String?
                var cursors = Set<String>()
                for page in 0..<100 {
                    let result = try transport.request("tools/list", params: cursor.map { ["cursor": $0] } ?? [:])
                    guard let entries = result["tools"] as? [[String: Any]] else { throw Failure(message: tr("tools/list did not return a valid tool array.")) }
                    tools += entries
                    guard tools.count <= 10_000 else { throw Failure(message: tr("Tool count exceeded the inspection limit; results are incomplete.")) }
                    if result["nextCursor"] == nil { cursor = nil; break }
                    guard let next = result["nextCursor"] as? String, !next.isEmpty, cursors.insert(next).inserted else { throw Failure(message: tr("Invalid or repeated pagination cursor; results are incomplete.")) }
                    cursor = next
                    if page == 99 { throw Failure(message: tr("Pagination exceeded the inspection limit; results are incomplete.")) }
                }
            }
            report.listingSeconds = clock() - listing
            let analysis = clock()
            report.instructions = TextFootprint(initialized["instructions"] as? String ?? "", encoding: env.tokenEncoding)
            var names = Set<String>()
            report.tools = try tools.map { tool in
                try transport.check()
                var row = try footprint(tool, encoding: env.tokenEncoding)
                if !names.insert(tool["name"] as? String ?? "").inserted { row.issues.append(tr("Duplicate tool name in the server listing.")) }
                return row
            }.sorted { ($0.definition.comparisonTokens ?? -1) == ($1.definition.comparisonTokens ?? -1) ? $0.name < $1.name : ($0.definition.comparisonTokens ?? -1) > ($1.definition.comparisonTokens ?? -1) }
            report.definitions = TextFootprint(try json(tools), encoding: env.tokenEncoding)
            report.analysisSeconds = clock() - analysis
            try transport.check()
            report.complete = true
            report.state = .ready
            report.message = tr("Handshake and complete tool listing succeeded. Business tool behavior has not been tested.")
        } catch let error as Failure {
            report.state = error.state
            report.tools = []
            report.definitions = nil
            report.message = Redact.text(error.message)
        } catch { report.message = tr("Inspection failed while launching or decoding protocol messages.") }
        return finish()
    }
}

protocol MCPTransport: AnyObject {
    func request(_ method: String, params: [String: Any]) throws -> [String: Any]
    func send(_ message: [String: Any]) throws
    func check() throws
    func negotiated(_ version: String)
    func close()
    var cleanupStatus: String? { get }
    var cleanupDetails: MCPCleanupDetails? { get }
}

extension MCPTransport {
    func negotiated(_ version: String) {}
    var cleanupStatus: String? { nil }
    var cleanupDetails: MCPCleanupDetails? { nil }
}

/// Synchronous, bounded JSONL transport. All pipe operations are nonblocking.
/// It owns only the child it starts; stderr is discarded, never mixed with protocol data.
final class MCPStdio: MCPTransport {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let deadline: Double
    let cancelled: () -> Bool
    var pending = Data()
    var received = 0
    var sequence = 0
    var closed = false

    init(executable: String, server: MCPServer, env: DoctorEnvironment, deadline: Double) throws {
        self.deadline = deadline
        cancelled = env.cancelled
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = server.args.map { env.expand($0, vars: server.env) }
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in server.env { environment[key] = env.expand(value) }
        environment["PATH"] = server.env["PATH"].map { env.expand($0) } ?? env.path.joined(separator: ":")
        process.environment = environment
        if let project = server.project { process.currentDirectoryURL = URL(fileURLWithPath: project) }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        for handle in [input.fileHandleForWriting, output.fileHandleForReading] {
            let fd = handle.fileDescriptor
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw MCPInspector.Failure(message: tr("Could not configure protocol pipes.")) }
        }
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw MCPInspector.Failure(message: tr("Could not configure protocol writes.")) }
        try process.run()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
    }

    func check() throws {
        if cancelled() { throw MCPInspector.Failure(state: .cancelled, message: tr("Inspection cancelled.")) }
        if MCPInspector.clock() >= deadline { throw MCPInspector.Failure(state: .timedOut, message: tr("Inspection timed out; tool definitions are incomplete.")) }
    }

    func send(_ message: [String: Any]) throws {
        let data = Data((try MCPInspector.json(message) + "\n").utf8)
        var offset = 0
        while offset < data.count {
            try check()
            let count = data.withUnsafeBytes { raw in Darwin.write(input.fileHandleForWriting.fileDescriptor, raw.baseAddress!.advanced(by: offset), data.count - offset) }
            if count > 0 { offset += count }
            else if count < 0 && (errno == EAGAIN || errno == EINTR) { usleep(2_000) }
            else { throw MCPInspector.Failure(message: tr("MCP server closed its input stream.")) }
        }
    }

    func receive() throws -> [String: Any] {
        var searchOffset = 0
        while true {
            try check()
            if let newline = pending.dropFirst(searchOffset).firstIndex(of: 10) {
                let line = pending.prefix(upTo: newline)
                pending.removeSubrange(...newline)
                guard let message = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], message["jsonrpc"] as? String == "2.0" else { throw MCPInspector.Failure(message: tr("Invalid JSON-RPC message on MCP stdout.")) }
                return message
            }
            searchOffset = pending.count
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            if count > 0 {
                received += count
                guard received <= 16_777_216, pending.count + count <= 8_388_608 else { throw MCPInspector.Failure(message: tr("MCP response exceeded the inspection size limit; results are incomplete.")) }
                pending.append(contentsOf: bytes.prefix(count))
            } else if count == 0 { throw MCPInspector.Failure(message: tr("MCP server closed stdout before a complete response.")) }
            else if errno == EAGAIN || errno == EINTR { usleep(2_000) }
            else { throw MCPInspector.Failure(message: tr("Could not read MCP stdout.")) }
        }
    }

    func request(_ method: String, params: [String: Any]) throws -> [String: Any] {
        sequence += 1
        let id = "thermo-\(sequence)"
        try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        while true {
            let message = try receive()
            if let serverMethod = message["method"] as? String {
                if let serverID = message["id"] {
                    if serverMethod == "ping" { try send(["jsonrpc": "2.0", "id": serverID, "result": [String: Any]()]) }
                    else { try send(["jsonrpc": "2.0", "id": serverID, "error": ["code": -32601, "message": "Inspector does not support this method."]]) }
                }
                continue
            }
            guard message["id"] as? String == id else { throw MCPInspector.Failure(message: tr("MCP response id does not match the pending request.")) }
            if let error = message["error"] as? [String: Any] {
                let code = error["code"] as? Int ?? 0
                // Do not echo server-controlled error text; it can include credentials or request data.
                throw MCPInspector.Failure(message: tr("MCP %1$@ returned JSON-RPC error %2$@.", method, String(code)))
            }
            guard message["error"] == nil, let result = message["result"] as? [String: Any] else { throw MCPInspector.Failure(message: tr("MCP response has no valid result object.")) }
            return result
        }
    }

    func close() {
        guard !closed else { return }; closed = true
        try? input.fileHandleForWriting.close()
        let grace = MCPInspector.clock() + 0.15
        while process.isRunning && MCPInspector.clock() < grace { usleep(5_000) }
        if process.isRunning {
            process.terminate()
            let terminated = MCPInspector.clock() + 0.15
            while process.isRunning && MCPInspector.clock() < terminated { usleep(5_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        try? output.fileHandleForReading.close()
    }
    deinit { if process.processIdentifier > 0 { close() } }
}
