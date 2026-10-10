import Foundation

public enum Severity: String, Codable, Comparable, CaseIterable, Sendable {
    case error, warning, info

    var rank: Int { self == .error ? 0 : self == .warning ? 1 : 2 }
    public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
}

public enum Area: String, Codable, CaseIterable, Sendable {
    case hooks, mcp, plugins, skills, statusline, launchd, processes
}

public struct Finding: Codable, Equatable, Sendable {
    public var severity: Severity
    public var area: Area
    /// Which agent's configuration this came from: claude, codex, cursor, gemini, or system.
    public var agent: String
    /// The thing at fault: a hook event, server name, plugin id, launchd label, …
    public var subject: String
    public var message: String
    public var fix: String?
    /// Where it was found (config file, plist, log); already redacted.
    public var source: String?

    public init(_ severity: Severity, _ area: Area, agent: String, subject: String,
                _ message: String, fix: String? = nil, source: String? = nil) {
        self.severity = severity
        self.area = area
        self.agent = agent
        self.subject = subject
        self.message = Redact.text(message)
        self.fix = fix.map(Redact.text)
        self.source = source
    }
}

public struct Inventory: Codable, Equatable, Sendable {
    public var agents: [String] = []
    public var hooks = 0
    public var mcpServers = 0
    public var plugins = 0
    public var skills = 0
    public var launchAgents = 0
}

/// AI-agent processes that share a binary/script, e.g. every copy of one MCP server.
public struct ProcessGroup: Codable, Equatable, Sendable {
    public var name: String
    public var count: Int
    public var detached: Int
    public var cpu: Double
    public var rssMB: Double
    public var oldest: TimeInterval
}

public struct DoctorReport: Codable, Sendable {
    public var generated: Date
    public var inventory: Inventory
    public var findings: [Finding]
    public var processes: [ProcessGroup]
    public var sessions: Int

    public func count(_ s: Severity) -> Int { findings.filter { $0.severity == s }.count }
}

/// Diagnostic output gets pasted into issues and chats, so nothing that looks like a credential leaves this module.
public enum Redact {
    static let secretName = try! NSRegularExpression(
        pattern: "(token|secret|password|passwd|api[_-]?key|apikey|auth|credential|private[_-]?key|cookie|session)",
        options: [.caseInsensitive])

    public static func isSecretName(_ name: String) -> Bool {
        secretName.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    /// A value that is a literal credential, not a reference like `${VAR}` or a file path.
    public static func isLiteralSecret(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespaces)
        if v.count < 8 || v.hasPrefix("$") || v.hasPrefix("/") || v.hasPrefix("~") || v.contains("${") { return false }
        if ["true", "false", "none", "null"].contains(v.lowercased()) { return false }
        return true
    }

    public static func value(_ v: String) -> String {
        v.count <= 4 ? "••••" : String(v.prefix(4)) + "••••"
    }

    static let patterns: [(NSRegularExpression, String)] = [
        // --token X, --api-key=X
        (try! NSRegularExpression(pattern: "(--?[A-Za-z0-9_-]*(?:token|secret|password|key|auth)[A-Za-z0-9_-]*(?:=|\\s+))([^\\s'\"]{4})[^\\s'\"]*",
                                  options: [.caseInsensitive]), "$1$2••••"),
        // FOO_TOKEN=X, "api_key": "X"
        (try! NSRegularExpression(pattern: "([A-Za-z0-9_]*(?:TOKEN|SECRET|PASSWORD|API_?KEY|AUTH)[A-Za-z0-9_]*[\"']?\\s*[=:]\\s*[\"']?)([^\\s'\"$]{4})[^\\s'\",;)\\]]*",
                                  options: [.caseInsensitive]), "$1$2••••"),
        // Bearer X
        (try! NSRegularExpression(pattern: "(Bearer\\s+)([^\\s'\"]{4})[^\\s'\"]*", options: []), "$1$2••••"),
        // Well-known key shapes anywhere.
        (try! NSRegularExpression(pattern: "\\b(sk-[A-Za-z0-9_-]{2}|ghp_|gho_|github_pat_|xox[abpr]-|AKIA|AIza)[A-Za-z0-9_-]{8,}", options: []), "$1••••"),
    ]

    public static func text(_ s: String) -> String {
        var out = s
        for (re, template) in patterns {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }
}
