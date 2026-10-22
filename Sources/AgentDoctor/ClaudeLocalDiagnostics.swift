import AgentCore
import CryptoKit
import Darwin
import Foundation

/// A deliberately small export contract. No raw identifiers, environment values, paths or logs.
public struct ClaudeLocalReport: Codable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let generatedAt: String
    public let platform: String
    public let readOnly: Bool
    public let networkPerformed: Bool
    public let complete: Bool
    public let checks: [ClaudeLocalCheck]
    public var json: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

public struct ClaudeLocalCheck: Codable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case observed, missing, permissionDenied = "permission-denied", unsupported, unknown, invalid, limited
        public var displayName: String {
            switch self {
            case .observed: return "Observed locally"
            case .missing: return "Not found locally"
            case .permissionDenied: return "Permission denied"
            case .unsupported: return "Unsupported format or source"
            case .unknown: return "Unknown"
            case .invalid: return "Invalid format"
            case .limited: return "Coverage limited"
            }
        }
    }
    public let id: String
    public let title: String
    public let status: Status
    public let value: String
    public let source: String
    public let note: String
}

/// User-initiated, passive diagnostics. Does not start Claude, execute shell configuration,
/// query feature flags, read credentials, modify IDs or make network requests.
public struct ClaudeLocalDiagnostics {
    public static let telemetryKeys = ["DISABLE_TELEMETRY", "DO_NOT_TRACK", "DISABLE_ERROR_REPORTING", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"]
    public static let routingKeys = ["ANTHROPIC_BASE_URL", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy"]
    public static let environmentKeys = telemetryKeys + routingKeys + ["CLAUDE_CONFIG_DIR"]
    let home: URL
    let environment: [String: String]
    let now: Date
    let processes: () -> ProcessTable
    let processEnvironment: (AgentProcess) -> [String: String]?
    let launchValue: (String) -> String?
    let applicationRoots: [URL]
    let maxBytes: Int

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                now: Date = Date(), applicationRoots: [URL]? = nil, maxBytes: Int = 1024 * 1024,
                processes: @escaping () -> ProcessTable = { ProcessTable.current(.init(cpu: false)) },
                processEnvironment: @escaping (AgentProcess) -> [String: String]? = ClaudeLocalDiagnostics.readProcessEnvironment,
                launchValue: @escaping (String) -> String? = { key in
                    {
                        let result = CommandRunner.run("/bin/launchctl", arguments: ["getenv", key], timeout: 2, captureError: false)
                        guard result.status == 0, !result.timedOut, !result.truncated else { return nil }
                        return result.output.trimmingCharacters(in: .newlines)
                    }()
                }) {
        self.home = home; self.environment = environment; self.now = now; self.maxBytes = max(1, min(maxBytes, 4 * 1024 * 1024))
        self.processes = processes; self.processEnvironment = processEnvironment; self.launchValue = launchValue
        self.applicationRoots = applicationRoots ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
    }

    public func scan() -> ClaudeLocalReport {
        var checks: [ClaudeLocalCheck] = []
        func add(_ id: String, _ title: String, _ status: ClaudeLocalCheck.Status, _ value: String, _ source: String, _ note: String = "") {
            checks.append(.init(id: id, title: title, status: status, value: value, source: source, note: note))
        }
        let table = processes()
        let cli = table.entries.filter { process in
            process.uid == getuid() && (process.name == "claude" || (process.executable ?? "").contains("/.local/share/claude/versions/") ||
                process.argv.contains { $0.hasSuffix("/cli.js") && $0.contains("/@anthropic-ai/claude-code/") })
        }
        let desktop = table.entries.filter { $0.uid == getuid() && $0.name == "Claude" && ($0.executable ?? "").contains("/Claude.app/Contents/MacOS/") }
        add("processes", "Claude processes", table.inventoryComplete ? .observed : .limited,
            "CLI: \(cli.count); Desktop: \(desktop.count)", "kernel-process-inventory", "Only current-user processes are inspected; an incomplete inventory is not proof that Claude is stopped.")

        var launch: [String: String] = [:]
        for key in Self.environmentKeys {
            if let value = launchValue(key) { launch[key] = value }
            else { add("launchd-unavailable.\(key)", key, .unknown, "Unavailable", "user-launchd-environment", "Unset and unreadable launchd variables cannot be distinguished by this probe.") }
        }
        var contexts: [(String, [String: String]?)] = [("thermo-launch-environment", environment), ("user-launchd-environment", launch)]
        var directories: [URL] = []
        func directory(_ value: String?) -> URL? {
            guard let value, !value.isEmpty else { return home.appendingPathComponent(".claude") }
            // Claude does not expand ~ or shell expressions in settings env values.
            guard value.hasPrefix("/"), !value.contains("\0"), value.utf8.count < 4096 else { return nil }
            return URL(fileURLWithPath: value).standardizedFileURL
        }
        for (index, process) in (cli + desktop).prefix(32).enumerated() {
            let values = processEnvironment(process)
            contexts.append(("claude-process-\(index + 1)", values))
        }
        if cli.count + desktop.count > 32 { add("process-limit", "Process coverage", .limited, "32-process limit", "kernel-process-inventory") }
        for (source, values) in contexts {
            guard let values else {
                add("\(source).environment", "Running process environment", .unknown, "Unavailable", source, "Process access failed or its identity changed. No effective configuration is inferred.")
                continue
            }
            for key in Self.telemetryKeys {
                if source == "user-launchd-environment", values[key] == nil { continue }
                add("\(source).\(key)", key, .observed, Self.telemetryState(key, value: values[key]), source,
                    "Environment snapshot only. Installed-version behavior and actual transmissions remain unverified; feature-flag-dependent functions may be affected.")
            }
            for key in Self.routingKeys {
                if source == "user-launchd-environment", values[key] == nil { continue }
                add("\(source).\(key)", key, .observed, Self.routeState(key, value: values[key]), source,
                    "Raw values are omitted. This does not establish the exit of any Claude request.")
            }
            if let path = directory(values["CLAUDE_CONFIG_DIR"]) {
                if !directories.contains(path) { directories.append(path) }
            } else { add("\(source).config-directory", "Claude configuration directory", .unsupported, "Not an absolute path", source) }
        }
        // The ordinary directory is always checked, even when the current context uses a custom one.
        let standard = home.appendingPathComponent(".claude")
        if !directories.contains(standard) { directories.insert(standard, at: 0) }
        var identities: [String] = []
        var configurationValues: [String: Set<String>] = [:]
        for (_, values) in contexts {
            guard let values else { continue }
            for key in Self.telemetryKeys + Self.routingKeys where values[key] != nil {
                let state = Self.telemetryKeys.contains(key) ? Self.telemetryState(key, value: values[key]) : Self.routeState(key, value: values[key])
                configurationValues[key, default: []].insert(state)
            }
        }
        for (index, dir) in directories.prefix(16).enumerated() {
            let source = dir == standard ? "default-claude-config" : "custom-claude-config-\(index + 1)"
            let global = dir == standard ? home.appendingPathComponent(".claude.json") : dir.appendingPathComponent(".claude.json")
            switch read(global) {
            case .success(let data):
                if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    for key in ["userID", "machineID"] {
                        let valid = (object[key] as? String).flatMap(Self.hexID)
                        add("\(source).\(key)", key, object[key] == nil ? .missing : valid == nil ? .invalid : .observed,
                            valid == nil ? "No recognized 64-hex identifier" : "64-hex identifier present", source,
                            "A local identifier is not evidence of account association, transmission or suspension.")
                        if key == "userID", let valid { identities.append(valid) }
                    }
                } else { add("\(source).identity", "CLI installation identifiers", .invalid, "Malformed JSON", source) }
            case .failure(let status): add("\(source).identity", "CLI installation identifiers", status, "Not inspected", source)
            }
            switch read(dir.appendingPathComponent("settings.json")) {
            case .success(let data):
                guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      object["env"] == nil || object["env"] is [String: Any] else {
                    add("\(source).settings", "Claude settings", .invalid, "Malformed settings/env", source); continue
                }
                let vars = object["env"] as? [String: Any] ?? [:]
                for key in Self.telemetryKeys + Self.routingKeys {
                    let state = Self.telemetryKeys.contains(key) ? Self.telemetryState(key, value: vars[key] as? String) : Self.routeState(key, value: vars[key] as? String)
                    if vars[key] is String { configurationValues[key, default: []].insert(state) }
                    add("\(source).settings.\(key)", key, vars[key] != nil && !(vars[key] is String) ? .invalid : .observed,
                        state, "\(source)-settings", "File configuration only; project/managed overrides and runtime application are not established.")
                }
            case .failure(let status): add("\(source).settings", "Claude settings", status, "Not inspected", source)
            }
        }
        if directories.count > 16 { add("directory-limit", "Configuration coverage", .limited, "16-directory limit", "local-configuration") }

        let differences = configurationValues.filter { $0.value.count > 1 }.keys.sorted()
        add("configuration-differences", "Configuration snapshot differences", .observed,
            differences.isEmpty ? "No differences in inspected categories" : differences.joined(separator: ", "), "local-comparison",
            "Different contexts can be intentional. Matching redacted categories do not establish matching URLs or effective precedence; raw values are not compared or exported.")
        var desktopIDs: [String] = []
        let desktopRoot = home.appendingPathComponent("Library/Application Support/Claude")
        switch read(desktopRoot.appendingPathComponent("ant-did")) {
        case .success(let data):
            let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let decoded = Data(base64Encoded: raw).flatMap { String(data: $0, encoding: .utf8) } ?? raw
            if let uuid = UUID(uuidString: decoded) {
                // Preserve the on-disk spelling for this specific comparison; never export its hash.
                desktopIDs.append(decoded)
                add("desktop.ant-did", "Desktop installation identifier", .observed, "UUID identifier present", "desktop-ant-did", "UUID format only; random generation and network use are not inferred.")
                _ = uuid
            } else { add("desktop.ant-did", "Desktop installation identifier", .invalid, "Unrecognized format", "desktop-ant-did") }
        case .failure(let status): add("desktop.ant-did", "Desktop installation identifier", status, "Not inspected", "desktop-ant-did")
        }
        if let did = desktopIDs.first, !identities.isEmpty {
            let hash = SHA256.hash(data: Data(did.utf8)).map { String(format: "%02x", $0) }.joined()
            add("identity-comparison", "Local CLI/Desktop identifier comparison", .observed,
                identities.contains(hash) ? "Matching local values" : "No match in inspected values", "local-comparison",
                "A match alone does not prove a feature flag, server linkage or an account restriction.")
        } else { add("identity-comparison", "Local CLI/Desktop identifier comparison", .unknown, "Insufficient local evidence", "local-comparison") }
        switch read(desktopRoot.appendingPathComponent("sentry/scope_v3.json")) {
        case .success(let data):
            if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                if let contexts = object["contexts"] as? [String: Any] {
                    for name in ["device", "os", "gpu", "gpu_1", "gpu_2", "gpu_3"] {
                        add("sentry.\(name)", "Sentry \(name) context", contexts[name] == nil ? .missing : .observed,
                            contexts[name] == nil ? "Not present in snapshot" : "Present; values omitted", "desktop-sentry-snapshot", "A local snapshot does not establish what was sent. Unknown fields are not interpreted.")
                    }
                } else { add("sentry.snapshot", "Sentry snapshot", .unsupported, "Unrecognized format", "desktop-sentry-snapshot") }
            } else { add("sentry.snapshot", "Sentry snapshot", .invalid, "Malformed JSON", "desktop-sentry-snapshot") }
        case .failure(let status): add("sentry.snapshot", "Sentry snapshot", status, "Not inspected", "desktop-sentry-snapshot")
        }
        var foundApp = false
        for root in applicationRoots {
            if case .success(let data) = read(root.appendingPathComponent("Claude.app/Contents/Info.plist")),
               let object = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
               let version = object["CFBundleShortVersionString"] as? String,
               version.range(of: "^[0-9]+(?:\\.[0-9]+){1,3}$", options: .regularExpression) != nil {
                foundApp = true
                add("desktop.version.\(checks.count)", "Desktop installed version", .observed, version, "desktop-bundle-metadata", "Presence of a field does not validate the behavior of this client version.")
            }
        }
        if !foundApp { add("desktop.version", "Desktop installed version", .unknown, "No readable recognized version", "desktop-bundle-metadata") }
        let versions = Set(cli.compactMap { p -> String? in
            guard let path = p.executable, path.contains("/.local/share/claude/versions/") else { return nil }
            let v = URL(fileURLWithPath: path).lastPathComponent
            return v.range(of: "^[0-9]+(?:\\.[0-9]+){1,3}$", options: .regularExpression) != nil ? v : nil
        }).sorted()
        add("cli.version", "CLI executable version label", versions.isEmpty ? .unknown : .observed,
            versions.isEmpty ? "Not established without executing CLI" : versions.joined(separator: ", "), "process-executable-metadata")
        add("feature-flags", "Server feature flags and account status", .unknown, "Not queried", "not-inspected", "No account request, model request, authentication or network probe is performed.")
        add("network-egress", "Claude request exit", .unknown, "Not measured", "not-inspected", "System proxies, browser probes and a configured URL do not prove the route of an actual Claude request.")
        let incomplete: Set<ClaudeLocalCheck.Status> = [.permissionDenied, .unsupported, .unknown, .invalid, .limited]
        return .init(schemaVersion: 1, kind: "thermo.claude-local-diagnostics", generatedAt: ISO8601DateFormatter().string(from: now),
                     platform: "macOS", readOnly: true, networkPerformed: false,
                     complete: !checks.contains { incomplete.contains($0.status) }, checks: checks)
    }

    static func hexID(_ value: String) -> String? {
        value.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil ? value.lowercased() : nil
    }
    public static func telemetryState(_ key: String, value: String?) -> String {
        guard let value, !value.isEmpty else { return "unset-or-empty" }
        if key == "DO_NOT_TRACK" {
            switch value.lowercased() {
            case "1", "true", "yes", "on": return "opt-out-requested"
            case "0", "false", "no", "off": return "opt-out-not-requested"
            default: return "unrecognized-boolean"
            }
        }
        return "opt-out-requested"
    }
    static func routeState(_ key: String, value: String?) -> String {
        guard let value, !value.isEmpty else { return "unset-or-empty" }
        if key.uppercased() == "NO_PROXY" { return "bypass-list-configured" }
        guard let url = URLComponents(string: value), let scheme = url.scheme?.lowercased(), url.host != nil else { return "configured-unrecognized-url" }
        if key == "ANTHROPIC_BASE_URL" {
            return scheme == "https" && url.host?.lowercased() == "api.anthropic.com" && url.user == nil && url.password == nil && (url.port == nil || url.port == 443) ? "official-api-host-configured" : "custom-endpoint-configured"
        }
        return ["http", "https", "socks", "socks5", "socks5h"].contains(scheme) ? "proxy-configured" : "configured-unrecognized-url"
    }
    private enum ReadResult { case success(Data), failure(ClaudeLocalCheck.Status) }
    private func read(_ url: URL) -> ReadResult {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .failure(errno == ENOENT ? .missing : [EACCES, EPERM].contains(errno) ? .permissionDenied : .unsupported) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return .failure(.unknown) }
        guard st.st_mode & S_IFMT == S_IFREG else { return .failure(.unsupported) }
        guard st.st_size >= 0, st.st_size <= maxBytes else { return .failure(.limited) }
        var bytes = [UInt8](repeating: 0, count: maxBytes + 1)
        var total = 0
        while total < bytes.count {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: total), $0.count - total) }
            if count < 0 { if errno == EINTR { continue }; return .failure(.unknown) }
            if count == 0 { break }; total += count
        }
        guard total <= maxBytes else { return .failure(.limited) }
        return .success(Data(bytes.prefix(total)))
    }

    /// Same-user allowlist only; the raw kernel buffer never enters a report or log.
    public static func readProcessEnvironment(_ process: AgentProcess) -> [String: String]? {
        guard let before = ProcessTable.identity(process.pid), before.uid == getuid(),
              before.executable == process.executable,
              process.sampledIdentity == nil || process.sampledIdentity == before else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, process.pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size <= 1024 * 1024 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0, size <= bytes.count else { return nil }
        bytes = Array(bytes.prefix(size))
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 0, argc <= 65536 else { return nil }
        var cursor = MemoryLayout<Int32>.size
        func string() -> String? {
            guard cursor < bytes.count, let end = bytes[cursor...].firstIndex(of: 0) else { return nil }
            defer { cursor = end + 1 }
            return String(bytes: bytes[cursor..<end], encoding: .utf8)
        }
        guard string() != nil else { return nil }
        while cursor < bytes.count && bytes[cursor] == 0 { cursor += 1 }
        for _ in 0..<argc { guard string() != nil else { return nil } }
        var output: [String: String] = [:]
        while cursor < bytes.count, let item = string(), !item.isEmpty {
            guard let equals = item.firstIndex(of: "=") else { continue }
            let key = String(item[..<equals])
            if environmentKeys.contains(key) { output[key] = String(item[item.index(after: equals)...]) }
        }
        guard ProcessTable.identity(process.pid) == before else { return nil }
        return output
    }
}
