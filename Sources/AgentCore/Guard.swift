import Darwin
import Foundation

/// Paths that are never removed or rewritten, whatever a rule says. Shared by disk cleanup and the
/// agent doctor's fixes so both refuse the same places. A candidate is refused if it is one of
/// these, contains one of these, or is outside the user's home.
public struct Guard: Sendable {
    public let home: String
    public let protected: [String]
    /// Nothing inside these may go either: keys, credentials, personal files, agent memory.
    let sealed: [String]
    /// Outside the home folder, only per-session folders below these roots may go (agent scratch space).
    let scratchRoots: [String]
    /// The per-user X folder where macOS keeps apps' code-sign clones; only
    /// `<X>/<bundle id>.code_sign_clone/<clone>` may go.
    let cloneRoots: [String]
    /// `/tmp` and the per-user temporary folder: only a top-level folder the user owns may go.
    let tempRoots: [String]
    let canonicalHome: String
    let canonicalProtected: [String]
    let canonicalSealed: [String]

    public init(home: String = NSHomeDirectory()) {
        self.home = home
        // Both spellings: resolving symlinks turns /private/tmp into /tmp.
        scratchRoots = ["/private/tmp/claude-\(getuid())", "/tmp/claude-\(getuid())"]
        let x = (NSTemporaryDirectory() as NSString).deletingLastPathComponent + "/X"
        let resolvedX = URL(fileURLWithPath: x).resolvingSymlinksInPath().path
        cloneRoots = Array(Set([x, resolvedX, resolvedX.hasPrefix("/private/") ? String(resolvedX.dropFirst("/private".count)) : resolvedX]))
        let t = (NSTemporaryDirectory() as NSString).standardizingPath
        let resolvedT = URL(fileURLWithPath: t).resolvingSymlinksInPath().path
        tempRoots = Array(Set(["/private/tmp", "/tmp", t, resolvedT, resolvedT.hasPrefix("/private/") ? String(resolvedT.dropFirst("/private".count)) : resolvedT]))
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
        canonicalHome = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        canonicalProtected = protected.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        canonicalSealed = sealed.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    }

    /// Resolves ancestors while preserving the final component: removing a symlink removes
    /// the link itself, whereas a symlink in its parent redirects the actual deletion.
    public static func deletionLocation(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path != "/" else { return "/" }
        return url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
    }

    /// Returns why `path` must not be removed, or nil when it may be.
    public func refusal(_ path: String) -> String? {
        if !path.hasPrefix("/") || path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) { return "relative path" }
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        if let why = refusal(p, home: home, protected: protected, sealed: sealed) { return why }
        return refusal(Self.deletionLocation(p), home: canonicalHome, protected: canonicalProtected, sealed: canonicalSealed)
    }

    private func refusal(_ p: String, home: String, protected: [String], sealed: [String]) -> String? {
        if let root = cloneRoots.first(where: { p.hasPrefix($0 + "/") }) {
            let parts = p.dropFirst(root.count + 1).split(separator: "/")
            return parts.count == 2 && parts[0].hasSuffix(".code_sign_clone") ? nil : "outside your home folder"
        }
        if let root = scratchRoots.first(where: { p.hasPrefix($0 + "/") }) {
            // <root>/<project>/<session>[/…]
            return p.dropFirst(root.count + 1).split(separator: "/").count >= 2 ? nil : "agent scratch root"
        }
        if !p.hasPrefix(home + "/"), p != home, !home.hasPrefix(p + "/"), let root = tempRoots.first(where: { p.hasPrefix($0 + "/") }) {
            let parts = p.dropFirst(root.count + 1).split(separator: "/")
            var st = stat()
            guard parts.count == 1, let name = parts.first, !name.hasPrefix("."), !name.hasPrefix("com.apple"), !name.hasPrefix("claude-") else { return "inside a temporary folder" }
            guard lstat(p, &st) == 0 else { return "not found" }
            return st.st_mode & S_IFMT == S_IFDIR && st.st_uid == getuid() ? nil : "not your folder"
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

