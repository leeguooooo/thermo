import AgentCore
import Darwin
import Foundation

/// `/private/tmp` and the per-user temporary folder as AI tools use them: build, audit and test
/// folders by the hundred, and git worktrees. macOS only purges them after three days, so they
/// churn through gigabytes a day. Grouped by the pattern of their names ("iphone-use-*-build");
/// git worktrees go through Git (Projects' worktree removal), never a plain delete.
enum TempFolders {
    /// `/private/tmp` and `$TMPDIR`.
    static var defaultRoots: [String] { ["/private/tmp", URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path] }

    /// Left alone however old: system and session sockets, the Claude scratch root (its own rule).
    static func reserved(_ name: String) -> Bool {
        name.hasPrefix(".") || name.hasPrefix("com.apple") || name.hasPrefix("tmux-") || name.hasPrefix("launch-")
            || name.hasPrefix("claude-") || name.hasPrefix("powerlog") || name == "TemporaryItems" || name.hasSuffix(".sock")
    }

    /// "iphone-use-3f9a2c-build" → "iphone-use-*-build": a part with a digit, or a long hex run, becomes `*`.
    static func pattern(_ name: String) -> String {
        var out = "", token = ""
        func flush() {
            let hex = token.count >= 6 && token.allSatisfy(\.isHexDigit)
            out += token.contains(where: \.isNumber) || hex ? "*" : token
            token = ""
        }
        for ch in name {
            if "-_.".contains(ch) { flush(); out.append(ch) } else { token.append(ch) }
        }
        flush()
        while out.contains("*-*") || out.contains("*_*") || out.contains("*.*") {
            out = out.replacingOccurrences(of: "*-*", with: "*").replacingOccurrences(of: "*_*", with: "*").replacingOccurrences(of: "*.*", with: "*")
        }
        return out
    }

    /// Which tool left it: "iphone-use" for iphone-use-…, else the first word ("thermo", "mu", "XcodeDistPipeline").
    static func producer(_ name: String) -> String {
        let tokens = name.split(whereSeparator: { "-_.".contains($0) }).map(String.init)
        guard let first = tokens.first, !first.contains(where: \.isNumber), first.count >= 2 else { return tr("other") }
        if tokens.count > 1, tokens[1] == "use" { return first + "-use" }
        return first
    }

    struct Entry {
        var path: String
        var newest: Date
        var size: TreeSize
        var worktree: Bool
    }

    static func scan(_ ctx: ScanContext, roots: [String] = defaultRoots, open: OpenFiles? = OpenFiles.current(),
                     minAge: TimeInterval = 6 * 3600) -> [CleanItem] {
        let uid = getuid()
        let cwds = ctx.processes.entries.compactMap(\.cwd)
        var groups: [String: [Entry]] = [:]
        var worktrees: [Entry] = []
        var seen = Set<String>()
        for root in roots {
            for path in FS.children(root) {
                guard ScanCancellation.current?.isCancelled != true else { return [] }
                let name = (path as NSString).lastPathComponent
                var st = stat()
                guard !reserved(name), lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == uid,
                      seen.insert(path).inserted else { continue }
                // In use: a process works inside it or has a file open there.
                if cwds.contains(where: { $0 == path || $0.hasPrefix(path + "/") }) || open?.holder(of: path) != nil { continue }
                let size = FS.size(path, trackNewest: true)
                let newest = max(size.newest ?? .distantPast, Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)))
                guard ctx.now.timeIntervalSince(newest) >= minAge, size.bytes > 0 || FS.exists(path + "/.git") else { continue }
                let worktree = FS.exists(path + "/.git") && !FS.isDirectory(path + "/.git")
                let entry = Entry(path: path, newest: newest, size: size, worktree: worktree)
                if worktree { worktrees.append(entry) } else { groups[producer(name), default: []].append(entry) }
            }
        }
        var items: [CleanItem] = []
        for (tool, entries) in groups {
            let size = entries.reduce(TreeSize()) { $0 + $1.size }
            // A single small folder is not worth a line of its own.
            guard size.bytes >= 50_000_000 || entries.count >= 5 else { continue }
            let newest = entries.map(\.newest).max()
            var patterns: [String: Int] = [:]
            for e in entries { patterns[pattern((e.path as NSString).lastPathComponent), default: 0] += 1 }
            let shown = patterns.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(3)
                .map { $0.value > 1 ? "\($0.key) ×\($0.value)" : $0.key }.joined(separator: ", ") + (patterns.count > 3 ? "…" : "")
            items.append(CleanItem(id: "temp/" + tool, category: .system, title: tr("Temporary folders: %1$@", tool),
                                   detail: trCount(entries.count, "%1$@ folder", "%1$@ folders") + " · " + tr("idle for %1$@", MemorySuspects.duration(ctx.now.timeIntervalSince(newest ?? ctx.now)))
                                       + " · " + shown,
                                   safety: .review, bytes: size.bytes, files: size.files, lastUsed: newest,
                                   paths: entries.sorted { $0.size.bytes > $1.size.bytes }.map(\.path),
                                   note: tr("left in a temporary folder by a tool; nothing has used them for %1$@ and no program has them open", MemorySuspects.duration(minAge))))
        }
        if !worktrees.isEmpty {
            let size = worktrees.reduce(TreeSize()) { $0 + $1.size }
            items.append(CleanItem(id: "temp-worktrees", category: .agentWorktrees, title: tr("Git worktrees in temporary folders"),
                                   detail: trCount(worktrees.count, "%1$@ worktree", "%1$@ worktrees"),
                                   safety: .review, bytes: size.bytes, files: size.files, lastUsed: worktrees.map(\.newest).max(),
                                   paths: worktrees.map(\.path),
                                   note: tr("removed through Git (git worktree remove) so the owning repository forgets them; worktrees with uncommitted changes are kept")))
        }
        return items.sorted { $0.bytes > $1.bytes }
    }
}
