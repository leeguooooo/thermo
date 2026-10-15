import AgentCore
import CryptoKit
import Darwin
import Foundation
import ThermoL10n

public struct StartupItem: Codable, Sendable, Identifiable {
    public var id: String { path }
    public var path: String
    public var label: String
    public var program: String?
    public var enabled: Bool?
    public var blocked: String?
    public var fingerprint: String?
}

public struct StartupReport: Codable, Sendable {
    public var scope = "userLaunchAgents"
    public var items: [StartupItem]
    public var issues: [String]
}

/// User LaunchAgents only. Changing the launchd override never rewrites a plist,
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

    static func read(_ path: String, home: String) -> (StartupItem, Bool)? {
        let root = home + "/Library/LaunchAgents"
        guard (path as NSString).deletingLastPathComponent == root, path.hasSuffix(".plist") else { return nil }
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(), st.st_mode & 0o022 == 0,
              st.st_size > 0, st.st_size <= 1_048_576,
              URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              data.count <= 1_048_576,
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let label = plist["Label"] as? String, validLabel(label) else { return nil }
        let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
        let fingerprint = "\(st.st_dev):\(st.st_ino):" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let protected = label.hasPrefix("com.apple.") || label.hasPrefix("dev.thermo.")
        return (StartupItem(path: path, label: label, program: program, enabled: nil,
                            blocked: protected ? "Manage this service in System Settings" : nil, fingerprint: fingerprint),
                !(plist["Disabled"] as? Bool ?? false))
    }

    public static func scan(home: String = NSHomeDirectory(), runner: Runner? = nil) -> StartupReport {
        let run = runner ?? command
        let root = home + "/Library/LaunchAgents"
        var report = StartupReport(items: [], issues: [])
        var overrides: [String: Bool]?
        do { overrides = try Self.overrides(run(["print-disabled", "gui/\(getuid())"])) }
        catch { report.issues.append(error.localizedDescription) }
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: root) }
        catch {
            if (error as NSError).code != NSFileNoSuchFileError { report.issues.append("Could not read your LaunchAgents folder") }
            return report
        }
        for name in names.sorted() where name.hasSuffix(".plist") {
            guard let (found, defaultEnabled) = read(root + "/" + name, home: home) else {
                report.issues.append(tr("Could not safely read startup file: %1$@", name))
                continue
            }
            var item = found
            if let overrides { item.enabled = overrides[item.label] ?? defaultEnabled }
            else { item.blocked = "Could not read startup state; refresh before changing it" }
            report.items.append(item)
        }
        let duplicates = Dictionary(grouping: report.items, by: \.label).filter { $0.value.count > 1 }.keys
        for i in report.items.indices where duplicates.contains(report.items[i].label) {
            report.items[i].blocked = "Several startup files use this label; resolve the duplicate first"
        }
        return report
    }

    /// The reviewed row is the plan; changing either the file or its effective state invalidates it.
    public static func setEnabled(_ enabled: Bool, item: StartupItem, home: String = NSHomeDirectory(), runner: Runner? = nil) throws -> StartupItem {
        let run = runner ?? command
        let action = enabled ? "enable" : "disable"
        do {
            let report = scan(home: home, runner: run)
            guard let current = report.items.first(where: { $0.path == item.path }), current.blocked == nil,
                  item.blocked == nil, item.fingerprint != nil, current.fingerprint == item.fingerprint,
                  current.label == item.label, let state = current.enabled, state == item.enabled else {
                throw Failure(message: "Startup item changed or could not be verified; refresh and review it again")
            }
            if state == enabled { return current }
            let result = run([action, "gui/\(getuid())/" + current.label])
            guard result.status == 0, !result.timedOut, !result.cancelled, !result.truncated else {
                throw Failure(message: "Startup change could not be confirmed; refresh to check its current state")
            }
            let after = scan(home: home, runner: run)
            guard let checked = after.items.first(where: { $0.path == current.path }), checked.fingerprint == current.fingerprint,
                  checked.enabled == enabled else {
                throw Failure(message: "Startup change could not be confirmed; refresh to check its current state")
            }
            OperationJournal.record(OperationRecord(feature: "apps", action: action, subject: current.label,
                items: [.init(target: current.path, status: "done", detail: "thermo apps startup \(enabled ? "disable" : "enable") \(current.label)")],
                undo: .init(kind: "startup", ref: current.label)), home: home)
            return checked
        } catch {
            OperationJournal.record(OperationRecord(feature: "apps", action: action, subject: item.label,
                items: [.init(target: item.path, status: "failed", detail: error.localizedDescription)]), home: home)
            throw error
        }
    }
}
