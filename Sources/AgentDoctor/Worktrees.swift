import Foundation
import ThermoL10n

/// The linked worktrees one repository has registered (`.git/worktrees/*`).
struct WorktreeCensus: Equatable {
    var repository: String
    var worktrees: [String]
    /// Registered worktrees whose folder is gone; only Git's bookkeeping is left.
    var missing: [String]
}

extension ConfigChecks {
    /// A repository with at least this many worktrees is worth a look; agents create one per task
    /// and rarely remove them.
    static let manyWorktrees = 10
    static let manyMissingWorktrees = 3

    /// Reads `.git/worktrees/*/gitdir` of one main checkout; nil when it is not one.
    static func worktreeCensus(_ repository: String) -> WorktreeCensus? {
        let admin = repository + "/.git/worktrees"
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repository + "/.git", isDirectory: &isDir), isDir.boolValue,
              let names = try? FileManager.default.contentsOfDirectory(atPath: admin) else { return nil }
        var census = WorktreeCensus(repository: repository, worktrees: [], missing: [])
        for name in names.sorted() {
            guard let data = FileManager.default.contents(atPath: admin + "/" + name + "/gitdir"), data.count < 4096,
                  let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty
            else { continue }
            let path = (line as NSString).deletingLastPathComponent
            census.worktrees.append(path)
            if !FileManager.default.fileExists(atPath: path) { census.missing.append(path) }
        }
        return census
    }

    /// The main checkout a project folder belongs to: itself, the repository a linked worktree
    /// points to, or the nearest folder above it with a `.git` folder.
    static func mainCheckout(_ path: String, home: String) -> String? {
        var dir = path
        while dir.count > home.count, dir.hasPrefix(home + "/") {
            let git = dir + "/.git"
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: git, isDirectory: &isDir) {
                if isDir.boolValue { return dir }
                guard let text = try? String(contentsOfFile: git, encoding: .utf8), text.hasPrefix("gitdir: "),
                      let r = text.range(of: "/.git/worktrees/", options: .backwards) else { return nil }
                return String(text[text.index(text.startIndex, offsetBy: "gitdir: ".count)..<r.lowerBound])
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// Repositories the agents work in that have piled up worktrees. Each one becomes an item; when
    /// some worktrees' folders are gone, its fix runs `git worktree prune`, which only drops that
    /// bookkeeping. The worktrees that still exist are removed from the disk cleanup, which checks
    /// each for unsaved work first.
    mutating func checkWorktrees() {
        guard !env.cancelled() else { return }
        let home = env.home.path
        var projects: [String] = []
        if let cj = env.json(env.url(".claude.json")) as? [String: Any], let p = cj["projects"] as? [String: Any] {
            projects = p.keys.sorted()
        }
        // Codex lists the folders it is trusted in as `[projects."<path>"]`.
        if let toml = try? String(contentsOf: env.url(".codex/config.toml"), encoding: .utf8) {
            for line in toml.split(separator: "\n") where line.hasPrefix("[projects.\"") && line.hasSuffix("\"]") {
                projects.append(String(line.dropFirst("[projects.\"".count).dropLast(2)))
            }
        }
        var seen = Set<String>()
        for project in projects {
            guard !env.cancelled() else { return }
            guard let repo = Self.mainCheckout(project, home: home), seen.insert(repo).inserted,
                  let census = Self.worktreeCensus(repo),
                  census.worktrees.count >= Self.manyWorktrees || census.missing.count >= Self.manyMissingWorktrees else { continue }
            let name = (repo as NSString).lastPathComponent
            item(.worktrees, agent: "shared", id: repo, name: name,
                 detail: tr("%1$@ worktrees", String(census.worktrees.count)), source: env.short(repo))
            defer { currentItem = nil }
            let message = census.missing.isEmpty
                ? tr("%1$@ has %2$@ worktrees; agents create one per task and rarely remove them", name, String(census.worktrees.count))
                : tr("%1$@ has %2$@ worktrees; %3$@ of them point to folders that no longer exist", name,
                     String(census.worktrees.count), String(census.missing.count))
            add(Finding(census.worktrees.count >= Self.manyWorktrees * 3 ? .warning : .info, .worktrees, agent: "shared", subject: name, message,
                        fix: tr("remove the merged, unchanged ones in Thermo → Disk → Agent worktrees; worktrees with unsaved work are kept"),
                        source: env.short(repo)))
            if !census.missing.isEmpty, let git = env.resolve("git") {
                offer(.fix, tr("Forget missing worktrees"),
                      tr("Runs git worktree prune: Git forgets the worktrees whose folders are already gone. No files are deleted."),
                      [.run(tool: git, args: ["-C", repo, "worktree", "prune"], cwd: nil)])
            }
        }
    }
}
