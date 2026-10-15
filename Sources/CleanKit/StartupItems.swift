import AgentCore
import CryptoKit
import Darwin
import Foundation
import ThermoL10n

public enum StartupScope: String, Codable, Sendable {
    case userAgent, sharedAgent, systemDaemon

    public var title: String {
        switch self {
        case .userAgent: return tr("User background startup")
        case .sharedAgent: return tr("Shared background startup (current user)")
        case .systemDaemon: return tr("System background service")
        }
    }
}

public struct StartupItem: Codable, Sendable, Identifiable {
    public var id: String { path }
    public var path: String
    public var label: String
    public var program: String?
    public var enabled: Bool?
    public var blocked: String?
    public var fingerprint: String?
    public var scope: StartupScope? = nil
    public var effectiveScope: StartupScope { scope ?? .userAgent }
}

public struct StartupReport: Codable, Sendable {
    public var scope = "launchServices"
    public var items: [StartupItem]
    public var issues: [String]
}

/// User and shared LaunchAgents plus system LaunchDaemons. Changing a user-domain override never rewrites a plist,
/// stops a running process, or starts an unloaded job.
public enum StartupItems {
    public struct Failure: LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
    }
    public typealias Runner = ([String]) -> CommandRunner.Result

    static func command(_ arguments: [String]) -> CommandRunner.Result {
        CommandRunner.run("/bin/launchctl", arguments: arguments, timeout: 10, outputLimit: 1_048_576)
    }

    static func validLabel(_ label: String) -> Bool {
        !label.isEmpty && label.utf8.count <= 255 && label.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || ".-_@".contains($0))
        }
    }

    /// launchctl uses enabled/disabled on recent macOS and true/false on older releases.
    static func overrides(_ result: CommandRunner.Result) throws -> [String: Bool] {
        let lines = result.output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard result.status == 0, !result.timedOut, !result.cancelled, !result.truncated,
              lines.first == "disabled services = {", lines.last == "}" else {
            throw Failure(message: "Could not read startup state; refresh before changing it")
        }
        var values: [String: Bool] = [:]
        for line in lines.dropFirst().dropLast() {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { throw Failure(message: "Could not read startup state; refresh before changing it") }
            let quoted = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard quoted.first == "\"", quoted.last == "\"", ["enabled", "disabled", "true", "false"].contains(value) else {
                throw Failure(message: "Could not read startup state; refresh before changing it")
            }
            let label = String(quoted.dropFirst().dropLast())
            guard values[label] == nil else { throw Failure(message: "Duplicate startup state; refresh before changing it") }
            values[label] = value == "enabled" || value == "false"
        }
        return values
    }

    struct Location {
        var path: String
        var scope: StartupScope
        var owner: uid_t
    }

    static func locations(home: String, includeSystem: Bool) -> [Location] {
        [.init(path: home + "/Library/LaunchAgents", scope: .userAgent, owner: getuid())] + (includeSystem ? [
            .init(path: "/Library/LaunchAgents", scope: .sharedAgent, owner: 0),
            .init(path: "/Library/LaunchDaemons", scope: .systemDaemon, owner: 0)
        ] : [])
    }

    static func read(_ path: String, location: Location) -> (StartupItem, Bool)? {
        guard (path as NSString).deletingLastPathComponent == location.path, path.hasSuffix(".plist") else { return nil }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == location.owner, st.st_mode & 0o022 == 0,
              st.st_size > 0, st.st_size <= 1_048_576,
              URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path,
              let data = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 1_048_577),
              data.count == st.st_size, FileIdentity.of(path) == "\(st.st_dev):\(st.st_ino)",
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let label = plist["Label"] as? String, validLabel(label) else { return nil }
        let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
        let fingerprint = "\(st.st_dev):\(st.st_ino):" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let protected = label.hasPrefix("com.apple.") || label.hasPrefix("dev.thermo.")
        let blocked = location.scope == .systemDaemon ? "System services require administrator management; open Login Items or the app's settings" : protected ? "Manage this service in System Settings" : nil
        return (StartupItem(path: path, label: label, program: program, enabled: nil,
                            blocked: blocked, fingerprint: fingerprint, scope: location.scope),
                !(plist["Disabled"] as? Bool ?? false))
    }

    public static func scan(home: String = NSHomeDirectory(), includeSystem: Bool = true, runner: Runner? = nil) -> StartupReport {
        scan(home: home, locations: locations(home: home, includeSystem: includeSystem), runner: runner)
    }

    static func scan(home: String, locations: [Location], runner: Runner?) -> StartupReport {
        let run = runner ?? command
        var report = StartupReport(items: [], issues: [])
        if locations.allSatisfy({ $0.scope == .userAgent }) { report.scope = "userLaunchAgents" }
        var states: [String: [String: Bool]] = [:]
        for domain in Set(locations.map { $0.scope == .systemDaemon ? "system" : "gui/\(getuid())" }).sorted() {
            do { states[domain] = try Self.overrides(run(["print-disabled", domain])) }
            catch { report.issues.append(domain + ": " + tr(error.localizedDescription)) }
        }
        for location in locations {
            let root = location.path
            let names: [String]
            do { names = try FileManager.default.contentsOfDirectory(atPath: root) }
            catch {
                if (error as NSError).code != NSFileNoSuchFileError { report.issues.append(tr("Could not safely read startup file: %1$@", root)) }
                continue
            }
            for name in names.sorted() where name.hasSuffix(".plist") {
                guard let (found, defaultEnabled) = read(root + "/" + name, location: location) else {
                    report.issues.append(tr("Could not safely read startup file: %1$@", root + "/" + name))
                    continue
                }
                var item = found
                if let overrides = states[location.scope == .systemDaemon ? "system" : "gui/\(getuid())"] { item.enabled = overrides[item.label] ?? defaultEnabled }
                else { item.blocked = item.blocked ?? "Could not read startup state; refresh before changing it" }
                report.items.append(item)
            }
        }
        let key: (StartupItem) -> String = { ($0.effectiveScope == .systemDaemon ? "system/" : "gui/") + $0.label }
        let duplicates = Dictionary(grouping: report.items, by: key).filter { $0.value.count > 1 }.keys
        for i in report.items.indices where duplicates.contains(key(report.items[i])) {
            report.items[i].blocked = "Several startup files use this label; resolve the duplicate first"
        }
        return report
    }

    /// The reviewed row is the plan; changing either the file or its effective state invalidates it.
    public static func setEnabled(_ enabled: Bool, item: StartupItem, home: String = NSHomeDirectory(), includeSystem: Bool = true, runner: Runner? = nil) throws -> StartupItem {
        try setEnabled(enabled, item: item, home: home, locations: locations(home: home, includeSystem: includeSystem), runner: runner)
    }

    static func setEnabled(_ enabled: Bool, item: StartupItem, home: String, locations: [Location], runner: Runner?) throws -> StartupItem {
        let run = runner ?? command
        let action = enabled ? "enable" : "disable"
        do {
            let report = scan(home: home, locations: locations, runner: run)
            guard let current = report.items.first(where: { $0.path == item.path }), current.blocked == nil,
                  item.blocked == nil, item.fingerprint != nil, current.fingerprint == item.fingerprint,
                  current.label == item.label, current.effectiveScope == item.effectiveScope,
                  current.effectiveScope != .systemDaemon, let state = current.enabled, state == item.enabled else {
                throw Failure(message: "Startup item changed or could not be verified; refresh and review it again")
            }
            if state == enabled { return current }
            let result = run([action, "gui/\(getuid())/" + current.label])
            guard result.status == 0, !result.timedOut, !result.cancelled, !result.truncated else {
                throw Failure(message: "Startup change could not be confirmed; refresh to check its current state")
            }
            let after = scan(home: home, locations: locations, runner: run)
            guard let checked = after.items.first(where: { $0.path == current.path }), checked.fingerprint == current.fingerprint,
                  checked.blocked == nil, checked.effectiveScope == current.effectiveScope, checked.enabled == enabled else {
                throw Failure(message: "Startup change could not be confirmed; refresh to check its current state")
            }
            let selector = "'" + current.path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
            OperationJournal.record(OperationRecord(feature: "apps", action: action, subject: current.label,
                items: [.init(target: current.path, status: "done", detail: "thermo apps startup \(enabled ? "disable" : "enable") \(selector)")],
                undo: .init(kind: "startup", ref: current.path)), home: home)
            return checked
        } catch {
            OperationJournal.record(OperationRecord(feature: "apps", action: action, subject: item.label,
                items: [.init(target: item.path, status: "failed", detail: error.localizedDescription)]), home: home)
            throw error
        }
    }
}
