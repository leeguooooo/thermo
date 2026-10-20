import Foundation
import ThermoL10n
import CryptoKit

public enum Severity: String, Codable, Comparable, CaseIterable, Sendable {
    case error, warning, info

    var rank: Int { self == .error ? 0 : self == .warning ? 1 : 2 }
    public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
}

public enum Area: String, Codable, CaseIterable, Sendable {
    case hooks, mcp, plugins, skills, statusline, launchd, processes, worktrees
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
    /// The `AgentItem.id` this is about; nil for findings about a whole area.
    public var item: String?

    public init(_ severity: Severity, _ area: Area, agent: String, subject: String,
                _ message: String, fix: String? = nil, source: String? = nil) {
        self.severity = severity
        self.area = area
        self.agent = Redact.text(agent)
        self.subject = Redact.text(subject)
        self.message = Redact.text(message)
        self.fix = fix.map(Redact.text)
        self.source = source.map(Redact.text)
    }
}

/// One thing the doctor looked at — a hook, MCP server, plugin, skill, launch agent or process group —
/// so a UI can list everything and mark which ones have problems.
public struct AgentItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var area: Area
    public var agent: String
    public var name: String
    /// One line: the command, url, state or size; already redacted.
    public var detail: String
    public var source: String?
    /// false for servers and plugins that are configured but turned off.
    public var enabled: Bool
    /// Worst finding about this item; nil when it looks healthy.
    public var severity: Severity?
    /// What the user can do about it: fix, disable, uninstall. Empty when it's managed elsewhere.
    public var actions: [Action] = []
    /// Static text measurements; never actual session consumption.
    public var skillFootprint: SkillFootprint? = nil
    /// A newer version than the installed one, when known.
    public var update: ExtensionUpdate? = nil
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
    /// MiB of resident memory (RSS, shared pages counted in every process); not phys_footprint.
    public var rssMB: Double
    public var oldest: TimeInterval
    public var memoryMetric: String = "resident"
}

public struct DoctorReport: Codable, Sendable {
    public var generated: Date
    public var inventory: Inventory
    public var findings: [Finding]
    public var items: [AgentItem]
    public var processes: [ProcessGroup]
    public var sessions: Int
    public var language: String? = nil
    public var cancelled: Bool? = nil

    public var hasResults: Bool { !items.isEmpty || !findings.isEmpty || !processes.isEmpty }

    /// Count each affected item once, plus problems that belong to the whole check.
    public var problemCount: Int {
        Self.problemCount(items: items, findings: findings)
    }

    public func problemCount(in area: Area) -> Int {
        Self.problemCount(items: items.filter { $0.area == area }, findings: findings.filter { $0.area == area })
    }

    private static func problemCount(items: [AgentItem], findings: [Finding]) -> Int {
        let itemIDs = Set(items.map(\.id))
        var affected = Set(items.filter { $0.severity == .error || $0.severity == .warning }.map(\.id))
        var general = 0
        for finding in findings where finding.severity == .error || finding.severity == .warning {
            if let id = finding.item, itemIDs.contains(id) { affected.insert(id) }
            else { general += 1 }
        }
        return affected.count + general
    }

    public func count(_ s: Severity) -> Int { findings.filter { $0.severity == s }.count }

    public func findings(for item: AgentItem) -> [Finding] { findings.filter { $0.item == item.id } }

    /// Findings not tied to one item (e.g. "5 hooks run on every tool call").
    public func general(_ area: Area) -> [Finding] {
        let known = Set(items.map(\.id))
        return findings.filter { $0.area == area && ($0.item == nil || !known.contains($0.item!)) }
    }
}

/// Diagnostic output gets pasted into issues and chats, so nothing that looks like a credential leaves this module.
public enum Redact {
    private static let credentialValueSyntax = #"(?:'.*?(?:'|$)|".*?(?:"|$)|[^\s'"。；，;,)&）】」』]+)"#
    private static let commandCredentials = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_-])(?=--?[A-Za-z0-9_-]+(?:=|\\s+)" + credentialValueSyntax + ")(--?[A-Za-z0-9_-]*(?:token|secret|password|key|auth)[A-Za-z0-9_-]*(?:=|\\s+))(?:(['\"])(.*?)(?:\\2|$)|([^\\s'\"。；，;,)&）】」』]+))", options: [.caseInsensitive])
    private static let assignedCredentials = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_])(?=[A-Za-z0-9_]+[\"']?\\s*[=:]\\s*" + credentialValueSyntax + ")([A-Za-z0-9_]*(?:TOKEN|SECRET|PASSWORD|API_?KEY|AUTH)[A-Za-z0-9_]*[\"']?\\s*[=:]\\s*)(?:(['\"])(.*?)(?:\\2|$)|([^\\s'\"。；，;,)&）】」』]+))", options: [.caseInsensitive])
    private static let bearerCredentials = try! NSRegularExpression(pattern: "\\bBearer\\s+([^\\s'\"。；，;,)&）】」』]+)", options: [.caseInsensitive])
    private static let urlCredentials = try! NSRegularExpression(pattern: "://([^/@\\s]+)@")
    public static func identifier(_ value: String) -> String {
        guard text(value) != value else { return value }
        return "redacted-" + SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func arguments(_ values: [String]) -> [String] {
        var expectsSecret = false
        return values.map { value in
            let result = expectsSecret && !value.hasPrefix("$") && !value.contains("${") ? "••••" : text(value)
            expectsSecret = (value.hasPrefix("-") && !value.contains("=") && isSecretName(value)) || value.lowercased() == "bearer"
            return result
        }
    }

    /// Preserve JSON structure while sanitizing presentation values and split argument arrays.
    public static func jsonExport(_ data: Data) throws -> Data {
        func sanitize(_ value: Any, key: String? = nil) -> Any {
            if let string = value as? String {
                if let key, isSecretName(key), !string.isEmpty, !string.hasPrefix("$"), !string.contains("${") { return "••••" }
                return key == "id" || key == "item" ? identifier(string) : text(string)
            }
            if let array = value as? [Any] {
                if key == "args", let strings = array as? [String] { return arguments(strings) }
                return array.map { sanitize($0) }
            }
            if let object = value as? [String: Any] {
                return object.reduce(into: [String: Any]()) {
                    $0[$1.key] = key == "kill" && $1.key == "args" ? "••••" : sanitize($1.value, key: $1.key)
                }
            }
            return value
        }
        let object = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        return try JSONSerialization.data(withJSONObject: sanitize(object), options: [.fragmentsAllowed, .sortedKeys, .prettyPrinted])
    }
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
        // Well-known key shapes anywhere.
        (try! NSRegularExpression(pattern: "\\b(sk-[A-Za-z0-9_-]{2}|ghp_|gho_|github_pat_|xox[abpr]-|AKIA|AIza)[A-Za-z0-9_-]{8,}", options: []), "$1••••"),
    ]

    public static func text(_ s: String) -> String {
        var out = s
        for match in commandCredentials.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
            let valueRange = match.range(at: match.range(at: 3).location == NSNotFound ? 4 : 3)
            guard let range = Range(valueRange, in: out), let prefix = Range(match.range(at: 1), in: out) else { continue }
            let value = String(out[range])
            if !value.hasPrefix("$"), !value.contains("${") {
                let replacement = out[prefix].lowercased().contains("password") ? "••••" : Self.value(value)
                out.replaceSubrange(range, with: replacement)
            }
        }
        for expression in [bearerCredentials, assignedCredentials, urlCredentials] {
            for match in expression.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
                let capture = expression === assignedCredentials ? (match.range(at: 3).location == NSNotFound ? 4 : 3) : 1
                guard let range = Range(match.range(at: capture), in: out) else { continue }
                let value = String(out[range])
                guard !value.hasPrefix("$"), !value.contains("${"), value.lowercased() != "bearer" else { continue }
                let prefix = Range(match.range(at: 1), in: out).map { out[$0].lowercased() } ?? ""
                let fullMask = expression === urlCredentials || (expression === assignedCredentials && prefix.contains("password"))
                out.replaceSubrange(range, with: fullMask ? "••••" : Self.value(value))
            }
        }
        for (re, template) in patterns {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }
}
