import Darwin
import Foundation

/// Where each agent keeps its state, relative to a home folder (fixtures pass their own).
public struct AgentHome: Sendable {
    public let home: String
    public init(home: String = NSHomeDirectory()) { self.home = home }

    public func path(_ rel: String) -> String { home + "/" + rel }

    public var claude: String { path(".claude") }
    public var claudeProjects: String { path(".claude/projects") }
    public var claudeSessions: String { path(".claude/sessions") }
    public var claudePlugins: String { path(".claude/plugins") }
    public var claudeVersions: String { path(".local/share/claude/versions") }
    public var codex: String { path(".codex") }
    public var gemini: String { path(".gemini") }
    public var cursor: String { path(".cursor") }
    public var opencode: String { path(".local/share/opencode") }

    /// `~/x` with this home.
    public func expand(_ p: String) -> String {
        p == "~" ? home : p.hasPrefix("~/") ? home + p.dropFirst() : p
    }

    public func tilde(_ p: String) -> String {
        p == home ? "~" : p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p
    }
}

/// A Claude Code process registered in `~/.claude/sessions/<pid>.json`.
public struct ClaudeLiveSession: Equatable, Sendable {
    public var sessionId: String
    public var pid: pid_t
    public var cwd: String?
    public var name: String?
    public var status: String?
    public var startedAt: Date?
    public var version: String?
}

public enum ClaudeSessions {
    /// Sessions whose process is still alive. `alive` is injectable for tests.
    public static func live(_ home: AgentHome = AgentHome(),
                            alive: (pid_t) -> Bool = { kill($0, 0) == 0 || errno == EPERM }) -> [ClaudeLiveSession] {
        let dir = home.claudeSessions
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        var out: [ClaudeLiveSession] = []
        for f in files where f.hasSuffix(".json") {
            guard let data = FileManager.default.contents(atPath: dir + "/" + f),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = o["sessionId"] as? String, let pid = (o["pid"] as? NSNumber)?.int32Value,
                  alive(pid) else { continue }
            out.append(ClaudeLiveSession(
                sessionId: sid, pid: pid, cwd: o["cwd"] as? String, name: o["name"] as? String,
                status: o["status"] as? String,
                startedAt: (o["startedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) },
                version: o["version"] as? String))
        }
        return out.sorted { $0.pid < $1.pid }
    }
}

/// `~/.claude/plugins/installed_plugins.json` (version 2: plugin id → installs).
public struct InstalledPlugin: Equatable, Sendable {
    public var id: String
    public var installPath: String
    public var scope: String
    public var projectPath: String?
    public var version: String?
}

public enum ClaudePlugins {
    public static func installed(_ home: AgentHome = AgentHome()) -> [InstalledPlugin] {
        guard let data = FileManager.default.contents(atPath: home.claudePlugins + "/installed_plugins.json"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = obj["plugins"] as? [String: Any] else { return [] }
        var out: [InstalledPlugin] = []
        for (id, value) in plugins {
            // Version 1 stored one object per plugin, version 2 a list of installs.
            let installs = (value as? [[String: Any]]) ?? ((value as? [String: Any]).map { [$0] } ?? [])
            for e in installs {
                guard let p = e["installPath"] as? String else { continue }
                out.append(InstalledPlugin(id: id, installPath: URL(fileURLWithPath: p).standardizedFileURL.path,
                                           scope: e["scope"] as? String ?? "user", projectPath: e["projectPath"] as? String,
                                           version: e["version"] as? String))
            }
        }
        return out.sorted { ($0.id, $0.installPath) < ($1.id, $1.installPath) }
    }
}
