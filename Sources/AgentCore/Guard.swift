import Darwin
import Foundation

/// Paths that are never removed or rewritten, whatever a rule says. Shared by disk cleanup and the
/// agent doctor's fixes so both refuse the same places. A candidate is refused if it is one of
/// these, contains one of these, or is outside the user's home.
public struct Guard: Sendable {
    public let home: String
    let protected: [String]
    /// Nothing inside these may go either: keys, credentials, personal files, agent memory.
    let sealed: [String]
    /// Outside the home folder, only per-session folders below these roots may go (agent scratch space).
    let scratchRoots: [String]

    public init(home: String = NSHomeDirectory()) {
        self.home = home
        scratchRoots = ["/private/tmp/claude-\(getuid())"]
        let rel = [
            "", "Library", "Library/Caches", "Library/Logs", "Library/Application Support", "Library/Containers",
            "Library/Group Containers", "Library/Keychains", "Library/Preferences", "Library/Mail", "Library/Messages",
            "Library/Mobile Documents", "Library/Photos", "Library/CloudStorage", "Library/Developer",
            "Library/Developer/Xcode", "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public",
            ".ssh", ".gnupg", ".aws", ".kube", ".docker", ".config", ".local", ".cache", ".Trash",
            ".claude", ".claude/projects", ".claude/settings.json", ".claude/.credentials.json", ".claude.json", ".claude/CLAUDE.md", ".claude/plugins",
            ".claude/skills", ".claude/agents", ".claude/commands", ".claude/agent-memory",
            ".codex", ".codex/sessions", ".codex/auth.json", ".codex/config.toml", ".codex/memories", ".codex/AGENTS.md",
            ".gemini", ".ollama", ".ollama/models", ".cargo", ".rustup", ".npm", ".bun", ".gradle", ".m2",
        ]
        protected = rel.map { $0.isEmpty ? home : home + "/" + $0 }
        sealed = [".ssh", ".gnupg", ".aws", ".kube", ".docker/config.json", ".netrc", ".config/gh",
                  "Library/Keychains", "Library/Mail", "Library/Messages", "Library/Mobile Documents", "Library/Photos",
                  "Library/CloudStorage", "Library/Preferences", "Desktop", "Documents", "Pictures", "Movies", "Music",
                  ".claude/agent-memory", ".codex/memories", ".claude/.credentials.json", ".codex/auth.json"]
            .map { home + "/" + $0 }
    }

    /// Returns why `path` must not be removed, or nil when it may be.
    public func refusal(_ path: String) -> String? {
        if path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) { return "relative path" }
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        if let root = scratchRoots.first(where: { p.hasPrefix($0 + "/") }) {
            // <root>/<project>/<session>[/…]
            return p.dropFirst(root.count + 1).split(separator: "/").count >= 2 ? nil : "agent scratch root"
        }
        guard p.hasPrefix(home + "/") else { return "outside your home folder" }
        for x in sealed where p == x || p.hasPrefix(x + "/") {
            return "inside protected location \(AgentHome(home: home).tilde(x))"
        }
        for x in protected where p == x || x.hasPrefix(p + "/") {
            return "protected location \(AgentHome(home: home).tilde(x))"
        }
        // Claude Code keeps per-project memory next to sessions; never touch it.
        if p.contains("/.claude/projects/"), p.split(separator: "/").contains("memory") { return "Claude memory" }
        if p.hasSuffix("/.git") || p.contains("/.git/") { return "git metadata" }
        return nil
    }
}

