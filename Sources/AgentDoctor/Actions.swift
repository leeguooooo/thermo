import Foundation
import ThermoL10n

public enum ActionKind: String, Codable, Sendable {
    /// Clears the item's problem and keeps the item.
    case fix
    /// Removes the item.
    case uninstall
    case disable
}

/// One concrete, reviewable operation. Shown to the user verbatim before anything runs.
public enum Step: Codable, Equatable, Sendable {
    /// An agent's own CLI, e.g. `claude mcp remove x -s user`; preferred over editing its files.
    case run(tool: String, args: [String], cwd: String?)
    /// Deletes a symlink itself, never what it points to.
    case unlink(path: String)
    /// Moves a file or folder to the Trash.
    case trash(path: String)
    /// SIGTERM, only if the process still has the command line seen at scan time.
    case kill(pid: Int32, args: String)
    /// Removes a key from a JSON config after backing it up.
    case removeJSONKey(file: String, path: [String])
    /// Removes one hook entry from a settings/hooks JSON file after backing it up.
    case removeHook(file: String, event: String, group: Int, hook: Int, command: String)
    /// Rewrites a LaunchAgent so a clean exit stays exited, then reloads it.
    case keepAliveOnFailure(plist: String, label: String)
    /// `launchctl bootout` a user LaunchAgent.
    case bootout(label: String)
    case truncate(path: String)

    /// A shell-like line for the confirmation dialog and `--dry-run`.
    public var display: String {
        func q(_ s: String) -> String { s.contains(" ") ? "'\(s)'" : s }
        switch self {
        case let .run(tool, args, cwd):
            return (cwd.map { "cd \(q($0)) && " } ?? "") + ([(tool as NSString).lastPathComponent] + args).map(q).joined(separator: " ")
        case let .unlink(path): return "rm \(q(path))   # symlink only"
        case let .trash(path): return tr("move %1$@ to the Trash", q(path))
        case let .kill(pid, args): return "kill -TERM \(pid)   # \(Redact.text(String(args.prefix(60))))"
        case let .removeJSONKey(file, path): return tr("remove %1$@ from %2$@ (backed up first)", path.joined(separator: "."), q(file))
        case let .removeHook(file, event, _, _, command):
            return tr("remove %1$@ hook \"%2$@\" from %3$@ (backed up first)", event, Redact.text(String(command.prefix(60))), q(file))
        case let .keepAliveOnFailure(plist, _): return tr("set KeepAlive = { SuccessfulExit = false } in %1$@ and reload it", q(plist))
        case let .bootout(label): return "launchctl bootout gui/$UID/\(label)"
        case let .truncate(path): return ": > \(q(path))"
        }
    }
}

public struct Action: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: ActionKind
    public var title: String
    /// What will happen, in one or two sentences.
    public var summary: String
    public var steps: [Step]
    public var destructive: Bool
    /// False when it interrupts something in use (e.g. a server a live session is connected to);
    /// `thermo agents fix` only applies bulk-safe fixes.
    public var bulk = true
}

public struct ActionResult: Sendable {
    public var ok: Bool
    public var log: [String]
    public var backups: [String]
}

/// Paths an action may never touch, whatever a finding says.
enum Guard {
    static func allowed(_ path: String, home: URL) -> Bool {
        let p = (path as NSString).standardizingPath
        let h = home.path
        guard p.hasPrefix(h + "/") else { return false }
        let rel = String(p.dropFirst(h.count + 1))
        let protected = [".ssh", ".gnupg", "Documents", "Desktop", "Pictures", "Movies", "Music", "Library/Keychains",
                         ".claude/projects", ".claude/memory", ".codex/sessions", ".git"]
        if rel.isEmpty || protected.contains(where: { rel == $0 || rel.hasPrefix($0 + "/") }) { return false }
        // Never a whole agent home or a top-level folder of home.
        return rel.contains("/") || rel.hasSuffix(".json") || rel.hasSuffix(".log")
    }
}

public enum ActionRunner {
    /// Runs every step in order; stops at the first failure. Each changed config is backed up first.
    public static func perform(_ action: Action, env: DoctorEnvironment) -> ActionResult {
        var log: [String] = []
        var backups: [String] = []
        let stamp = ISO8601DateFormatter().string(from: env.now).replacingOccurrences(of: ":", with: "")
        let backupDir = env.backupRoot.appendingPathComponent(stamp)

        func backup(_ file: String) throws {
            try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
            let name = file.replacingOccurrences(of: env.home.path + "/", with: "").replacingOccurrences(of: "/", with: "__")
            let dest = backupDir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.copyItem(atPath: file, toPath: dest.path)
            }
            backups.append(dest.path)
        }

        for step in action.steps {
            do {
                try perform(step, env: env, backup: backup)
                log.append("✓ " + step.display)
                record(env, action: action, step: step)
            } catch {
                log.append("✗ " + step.display + " — " + "\(error)")
                return ActionResult(ok: false, log: log, backups: backups)
            }
        }
        return ActionResult(ok: true, log: log, backups: backups)
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    static func perform(_ step: Step, env: DoctorEnvironment, backup: (String) throws -> Void) throws {
        let fm = FileManager.default
        func check(_ path: String) throws {
            guard Guard.allowed(path, home: env.home) else { throw Failure(tr("refusing to touch protected path %1$@", path)) }
        }
        switch step {
        case let .run(tool, args, cwd):
            let r = env.execute(tool, args, cwd)
            guard r.status == 0 else { throw Failure(r.output.trimmingCharacters(in: .whitespacesAndNewlines)) }

        case let .unlink(path):
            try check(path)
            let attrs = try fm.attributesOfItem(atPath: path)
            guard attrs[.type] as? FileAttributeType == .typeSymbolicLink else { throw Failure(tr("%1$@ is not a symlink", path)) }
            try fm.removeItem(atPath: path)  // removes the link, not its target

        case let .trash(path):
            try check(path)
            try env.trash(URL(fileURLWithPath: path))

        case let .kill(pid, args):
            // The pid may have been reused since the scan.
            let now = env.run("/bin/ps", ["-o", "args=", "-p", String(pid)])?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let now, !now.isEmpty else { return }  // already gone
            guard now == args else { throw Failure(tr("pid %1$@ is now a different process; not killed", String(pid))) }
            guard env.signal(pid, SIGTERM) else { throw Failure(tr("could not signal pid %1$@", String(pid))) }

        case let .removeJSONKey(file, path):
            try check(file)
            var root = try readJSON(file)
            guard remove(path, from: &root) else { return }  // already gone
            try backup(file)
            try writeJSON(root, to: file)

        case let .removeHook(file, event, group, hook, command):
            try check(file)
            var root = try readJSON(file)
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            var groups = hooks[event] as? [[String: Any]] ?? []
            guard group < groups.count, var list = groups[group]["hooks"] as? [[String: Any]], hook < list.count,
                  list[hook]["command"] as? String == command else {
                throw Failure(tr("the hook changed since the scan; rescan and try again"))
            }
            list.remove(at: hook)
            if list.isEmpty { groups.remove(at: group) } else { groups[group]["hooks"] = list }
            if groups.isEmpty { hooks[event] = nil } else { hooks[event] = groups }
            root["hooks"] = hooks
            try backup(file)
            try writeJSON(root, to: file)

        case let .keepAliveOnFailure(plist, label):
            try check(plist)
            let data = try Data(contentsOf: URL(fileURLWithPath: plist))
            guard var d = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw Failure(tr("%1$@ is not a property list", plist))
            }
            try backup(plist)
            d["KeepAlive"] = ["SuccessfulExit": false]
            let out = try PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0)
            try out.write(to: URL(fileURLWithPath: plist), options: .atomic)
            _ = env.execute("/bin/launchctl", ["bootout", "gui/\(env.uid)/\(label)"], nil)
            let r = env.execute("/bin/launchctl", ["bootstrap", "gui/\(env.uid)", plist], nil)
            guard r.status == 0 else { throw Failure(r.output) }

        case let .bootout(label):
            let r = env.execute("/bin/launchctl", ["bootout", "gui/\(env.uid)/\(label)"], nil)
            // 3 = "No such process": not loaded, which is what we want.
            guard r.status == 0 || r.status == 3 || r.output.contains("No such process") else { throw Failure(r.output) }

        case let .truncate(path):
            try check(path)
            try FileHandle(forWritingTo: URL(fileURLWithPath: path)).truncate(atOffset: 0)
        }
    }

    static func readJSON(_ file: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: file))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(tr("%1$@ is not a JSON object", file))
        }
        return root
    }

    static func writeJSON(_ root: [String: Any], to file: String) throws {
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: URL(fileURLWithPath: file), options: .atomic)
    }

    /// Removes the value at a key path; false if it wasn't there.
    static func remove(_ path: [String], from dict: inout [String: Any]) -> Bool {
        guard let first = path.first else { return false }
        if path.count == 1 { return dict.removeValue(forKey: first) != nil }
        guard var child = dict[first] as? [String: Any] else { return false }
        let removed = remove(Array(path.dropFirst()), from: &child)
        dict[first] = child
        return removed
    }

    /// One line per step in ~/Library/Logs/Thermo/fix.log: `<ISO time> <action> <id> <what>`.
    static func record(_ env: DoctorEnvironment, action: Action, step: Step) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(action.kind.rawValue) \(action.id) \(Redact.text(step.display))\n"
        let url = env.logFile
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.data(using: .utf8)!.write(to: url)
        }
    }
}
