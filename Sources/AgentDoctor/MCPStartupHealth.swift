import Darwin
import Foundation
import ThermoL10n

/// One server's unresolved startup state. Holds classified fields only: log error text can
/// carry endpoints, headers or response bodies, so it never leaves the parser.
public struct MCPStartupServer: Codable, Equatable, Sendable {
    public let name: String
    public let status: String
    public let httpStatus: Int?
    public let failure: String?
    /// Failed startup attempts since the last `ready`. One app launch can attempt several times.
    public let consecutiveFailures: Int
    public let lastFailureAt: String?
    public let lastReadyAt: String?
}

public struct MCPStartupHealthReport: Codable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let generatedAt: String
    public let since: String
    public let agent: String
    public let source: String
    public let readOnly: Bool
    public let networkPerformed: Bool
    /// observed, missing or permission-denied. Only `observed` can support "no failures".
    public let logStatus: String
    public let logFilesRead: Int
    /// False when a file or byte limit left part of the window unread.
    public let complete: Bool
    public let healthyServers: Int
    public let unhealthy: [MCPStartupServer]
    public var json: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

struct MCPStartupEvent: Equatable {
    var date: Date
    var server: String
    var status: String
    var httpStatus: Int?
    var failure: String?
}

/// Passive reader of Codex Desktop's `mcp_server_startup_status_updated` log lines. It never
/// connects to a server; use `agents inspect` for a live probe.
public struct MCPStartupHealth {
    static let marker = "mcp_server_startup_status_updated"
    let home: URL
    let now: Date
    let maxFiles: Int
    let maxBytesPerFile: Int

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = Date(),
                maxFiles: Int = 400, maxBytesPerFile: Int = 8 << 20) {
        self.home = home; self.now = now; self.maxFiles = maxFiles; self.maxBytesPerFile = maxBytesPerFile
    }

    public func scan(since: Date) -> MCPStartupHealthReport {
        let root = home.appendingPathComponent("Library/Logs/com.openai.codex")
        let fm = FileManager.default
        var logStatus = "observed", complete = true
        var files: [(url: URL, modified: Date)] = []
        if !fm.fileExists(atPath: root.path) { logStatus = "missing" }
        else if !fm.isReadableFile(atPath: root.path) { logStatus = "permission-denied"; complete = false }
        else if let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey]) {
            for case let url as URL in walker {
                guard url.lastPathComponent.hasPrefix("codex-desktop-"), url.pathExtension == "log",
                      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                      values.isRegularFile == true, let modified = values.contentModificationDate, modified >= since else { continue }
                files.append((url, modified))
            }
        }
        files.sort { $0.modified > $1.modified }
        if files.count > maxFiles { files.removeLast(files.count - maxFiles); complete = false }
        var events: [MCPStartupEvent] = []
        for file in files {
            guard let (text, truncated) = Self.tail(of: file.url, limit: maxBytesPerFile) else { complete = false; continue }
            if truncated { complete = false }
            events += Self.events(in: text)
        }
        let summary = Self.summarize(events.filter { $0.date >= since })
        return MCPStartupHealthReport(
            schemaVersion: 1, kind: "thermo.mcp-startup-health", generatedAt: Self.stamp(now), since: Self.stamp(since),
            agent: "codex", source: "codex-desktop-logs", readOnly: true, networkPerformed: false,
            logStatus: logStatus, logFilesRead: files.count, complete: complete,
            healthyServers: summary.healthy, unhealthy: summary.unhealthy)
    }

    static func tail(of url: URL, limit: Int) -> (String, Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let truncated = size > UInt64(limit)
        guard (try? handle.seek(toOffset: truncated ? size - UInt64(limit) : 0)) != nil else { return nil }
        // readToEnd returns nil, not empty data, for an empty file; only a throw is a read failure.
        let data: Data
        do { data = try handle.readToEnd() ?? Data() } catch { return nil }
        return (String(decoding: data, as: UTF8.self), truncated)
    }

    static func events(in text: String) -> [MCPStartupEvent] {
        text.split(whereSeparator: \.isNewline).compactMap { $0.contains(marker) ? parse(String($0)) : nil }
    }

    /// `<timestamp> <level> [scope] mcp_server_startup_status_updated key=value key="quoted"`.
    /// Fields are tokenized so text inside a quoted error can never pose as `server=` or `status=`.
    static func parse(_ line: String) -> MCPStartupEvent? {
        guard let range = line.range(of: marker),
              let date = date(String(line.prefix { $0 != " " })) else { return nil }
        var fields: [String: String] = [:]
        var rest = Substring(line[range.upperBound...])
        while true {
            rest = rest.drop { $0 == " " }
            guard let equals = rest.firstIndex(of: "=") else { break }
            let key = String(rest[..<equals])
            rest = rest[rest.index(after: equals)...]
            if rest.first == "\"" {
                rest = rest.dropFirst()
                var value = "", escaped = false, end = rest.endIndex
                for index in rest.indices {
                    let character = rest[index]
                    if escaped { value.append(character); escaped = false }
                    else if character == "\\" { escaped = true }
                    else if character == "\"" { end = index; break }
                    else { value.append(character) }
                }
                fields[key] = value
                rest = end == rest.endIndex ? rest[end...] : rest[rest.index(after: end)...]
            } else {
                let end = rest.firstIndex(of: " ") ?? rest.endIndex
                fields[key] = String(rest[..<end])
                rest = rest[end...]
            }
        }
        guard let server = fields["server"], !server.isEmpty, server.count <= 128,
              let status = fields["status"], !status.isEmpty else { return nil }
        let error = fields["error"].flatMap { $0 == "null" ? nil : $0 } ?? fields["failureReason"].flatMap { $0 == "null" ? nil : $0 }
        let (http, failure) = error.map(classify) ?? (nil, nil)
        return MCPStartupEvent(date: date, server: server, status: status, httpStatus: http, failure: failure)
    }

    static func classify(_ error: String) -> (Int?, String) {
        let text = error.lowercased()
        if let range = text.range(of: #"http (status )?[1-5][0-9]{2}\b"#, options: .regularExpression),
           let code = Int(text[range].suffix(3)) { return (code, "http-status") }
        if text.contains("timed out") || text.contains("timeout") { return (nil, "timeout") }
        if text.contains("connection closed") { return (nil, "connection-closed") }
        return (nil, "other")
    }

    /// The latest terminal state per server decides health. `cancelled` follows a failure when
    /// Codex abandons the attempt, so it neither counts as a failure nor clears one.
    static func summarize(_ input: [MCPStartupEvent]) -> (healthy: Int, unhealthy: [MCPStartupServer]) {
        struct State { var cancelled = false; var ready = false; var failures = 0; var last: MCPStartupEvent?; var lastReady: Date? }
        // Several log files can record one event.
        var seen = Set<String>()
        let events = input.sorted { $0.date < $1.date }.filter {
            seen.insert("\($0.date.timeIntervalSince1970)|\($0.server)|\($0.status)").inserted
        }
        var states: [String: State] = [:]
        for event in events {
            var state = states[event.server] ?? State()
            switch event.status {
            case "ready": state = State(ready: true, lastReady: event.date)
            case "failed": state.failures += 1; state.ready = false; state.cancelled = false; state.last = event
            case "cancelled": if state.failures == 0 && !state.ready { state.cancelled = true }
            default: break
            }
            states[event.server] = state
        }
        let healthy = states.values.filter(\.ready).count
        let unhealthy = states.compactMap { name, state -> MCPStartupServer? in
            guard state.failures > 0 || state.cancelled else { return nil }
            return MCPStartupServer(name: name, status: state.failures > 0 ? "failed" : "cancelled",
                                    httpStatus: state.last?.httpStatus, failure: state.last?.failure,
                                    consecutiveFailures: state.failures, lastFailureAt: state.last.map { stamp($0.date) },
                                    lastReadyAt: state.lastReady.map(stamp))
        }.sorted { ($0.consecutiveFailures, $1.name) > ($1.consecutiveFailures, $0.name) }
        return (healthy, unhealthy)
    }

    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    static func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}

extension MCPStartupServer {
    public var reason: String {
        if let httpStatus { return "HTTP \(httpStatus)" }
        switch failure {
        case "timeout": return tr("timed out")
        case "connection-closed": return tr("connection closed during startup")
        case nil: return tr("startup cancelled")
        default: return tr("startup failed")
        }
    }
}

extension ConfigChecks {
    /// Repeated failures only, and only for servers still enabled in config, so one transient
    /// outage or an already removed server does not raise a standing warning.
    mutating func checkMCPStartup() {
        let report = MCPStartupHealth(home: env.home, now: env.now, maxFiles: 64, maxBytesPerFile: 4 << 20)
            .scan(since: env.now.addingTimeInterval(-3 * 86400))
        for server in report.unhealthy where server.consecutiveFailures >= 2 {
            guard let item = items.first(where: {
                $0.area == .mcp && $0.agent == "codex" && $0.enabled && ($0.name == server.name || $0.name.hasPrefix(server.name + " ("))
            }) else { continue }
            var finding = Finding(.warning, .mcp, agent: "codex", subject: item.name,
                                  tr("failed %1$@ consecutive startups in Codex Desktop: %2$@", String(server.consecutiveFailures), server.reason),
                                  fix: tr("run `thermo agents inspect %1$@`, then repair the server or disable it", server.name),
                                  source: "~/Library/Logs/com.openai.codex")
            finding.item = item.id
            add(finding)
        }
    }
}
