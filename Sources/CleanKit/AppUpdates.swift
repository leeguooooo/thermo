import AgentCore
import CryptoKit
import Foundation

public struct AppUpdate: Codable, Sendable, Identifiable {
    public var id: String { token }
    public var token: String
    public var name: String
    public var installedVersions: [String]
    public var targetVersion: String
    public var appPaths: [String]
    public var bundleIDs: [String: String]
    public var identities: [String: AppReviewIdentity]
    public var definition: String
    public var brew: String
    public var brewIdentity: String?
    public var blocked: String?
}

public struct AppUpdateReport: Codable, Sendable {
    public var scope = "homebrewCasks"
    public var checked = Date()
    public var catalogRefreshed = false
    public var items: [AppUpdate] = []
    public var skipped: [String: String] = [:]
    public var issues: [String] = []
}

public struct AppUpdateResult: Codable, Sendable {
    public var token: String
    /// succeeded | failed | unconfirmed. A successful subprocess alone is insufficient.
    public var outcome: String
    public var message: String
    public var versions: [String: String] = [:]
}

/// Delegates installation to the already-installed Homebrew. No root helper, shell,
/// automatic cleanup, dependent upgrades, or force-overwrites. Requests no-quit mode;
/// vendor installation steps remain Homebrew's responsibility.
public enum AppUpdates {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }
    public typealias Runner = (_ brew: String, _ arguments: [String], _ timeout: TimeInterval) -> CommandRunner.Result

    static func run(_ brew: String, _ arguments: [String], _ timeout: TimeInterval) -> CommandRunner.Result {
        var environment = ProcessInfo.processInfo.environment
        for key in ["HOMEBREW_NO_AUTO_UPDATE", "HOMEBREW_NO_ANALYTICS", "HOMEBREW_NO_INSTALL_CLEANUP", "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK"] {
            environment[key] = "1"
        }
        return CommandRunner.run(brew, arguments: arguments, environment: environment, timeout: timeout,
                                 outputLimit: 4_194_304, captureError: false)
    }

    static func json(_ result: CommandRunner.Result) throws -> [String: Any] {
        guard result.status == 0, !result.timedOut, !result.cancelled, !result.truncated,
              let object = (try? JSONSerialization.jsonObject(with: Data(result.output.utf8))) as? [String: Any] else {
            throw Failure(message: "Could not read Homebrew update information; check Homebrew and try again")
        }
        return object
    }

    static func validToken(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return [1, 3].contains(parts.count) && parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && part.first != "-" && part.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || "-_.+@".contains($0))
            }
        }
    }

    static func executableIdentity(_ path: String) -> String? {
        guard let link = FileIdentity.of(path), let target = FileIdentity.of(URL(fileURLWithPath: path).resolvingSymlinksInPath().path) else { return nil }
        return link + ":" + target
    }

    static func definition(_ info: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func baseVersion(_ version: String) -> String { String(version.split(separator: ",", maxSplits: 1).first ?? "") }

    static func bundleMatches(_ path: String, version: String) -> Bool {
        guard let app = AppUninstaller.read(path), app.version == baseVersion(version) else { return false }
        let parts = version.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count > 1 else { return true }
        guard parts.count == 2, let plist = NSDictionary(contentsOfFile: path + "/Contents/Info.plist") else { return false }
        return plist["CFBundleVersion"] as? String == String(parts[1])
    }

    static func appPaths(_ info: [String: Any], home: String) -> [String] {
        let roots = ["/Applications", "/Applications/Utilities", home + "/Applications"]
        var paths: [String] = []
        for artifact in info["artifacts"] as? [[String: Any]] ?? [] {
            guard let app = (artifact["app"] as? [Any])?.first as? String else { continue }
            if let target = artifact["target"] as? String, target.hasPrefix("/") {
                guard roots.contains((target as NSString).deletingLastPathComponent), target.hasSuffix(".app") else { return [] }
                paths.append(target)
            } else {
                let name = ((artifact["app"] as? [Any])?.last as? [String: Any])?["target"] as? String ?? (app as NSString).lastPathComponent
                guard !name.contains("/"), name.hasSuffix(".app") else { return [] }
                let found = roots.map { $0 + "/" + name }.filter(FS.exists)
                guard found.count == 1 else { return [] }
                paths += found
            }
        }
        return Array(Set(paths)).sorted()
    }

    public static func scan(refreshCatalog: Bool = false, brew requested: String? = nil, home: String = NSHomeDirectory(),
                            runner: Runner? = nil, processes: ProcessTable? = nil) -> AppUpdateReport {
        var report = AppUpdateReport()
        guard let brew = requested ?? ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            report.issues = ["Homebrew was not found; App Store and other app updates are managed separately"]
            return report
        }
        let command = runner ?? run
        if runner == nil, !["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].contains(brew) || !FileManager.default.isExecutableFile(atPath: brew) {
            report.issues = ["Could not verify Homebrew; check it before updating"]
            return report
        }
        do {
            if refreshCatalog {
                let refresh = command(brew, ["update", "--quiet"], 120)
                guard refresh.status == 0, !refresh.timedOut, !refresh.cancelled else {
                    throw Failure(message: "Homebrew catalog refresh failed; no updates were installed")
                }
                report.catalogRefreshed = true
            }
            let outdated = try json(command(brew, ["outdated", "--cask", "--json=v2", "--greedy"], 60))
            guard let rows = outdated["casks"] as? [[String: Any]] else { throw Failure(message: "Homebrew returned an unsupported update format") }
            guard rows.count <= 128 else { throw Failure(message: "Too many Homebrew updates; use Homebrew to update in smaller groups") }
            let tokens = rows.compactMap { $0["name"] as? String }
            guard tokens.count == rows.count, Set(tokens).count == tokens.count, tokens.allSatisfy(validToken) else {
                throw Failure(message: "Homebrew returned an unsupported update format")
            }
            if tokens.isEmpty { return report }
            let allInfo = try json(command(brew, ["info", "--cask", "--json=v2"] + tokens, 60))
            guard let casks = allInfo["casks"] as? [[String: Any]] else { throw Failure(message: "Homebrew returned an unsupported update format") }
            let table = processes ?? ProcessTable.current(.init(cpu: false))
            for row in rows {
                let token = row["name"] as! String
                let matches = casks.filter { ($0["full_token"] as? String ?? $0["token"] as? String) == token }
                guard matches.count == 1, let info = matches.first, let target = row["current_version"] as? String,
                      let installed = row["installed_versions"] as? [String], !installed.isEmpty, !target.isEmpty,
                      let recorded = info["installed"] as? String, installed.contains(recorded),
                      info["version"] as? String == target else {
                    report.skipped[token] = "Update metadata changed or is incomplete; check again"
                    continue
                }
                let paths = appPaths(info, home: home)
                guard !paths.isEmpty else { report.skipped[token] = "This cask has no supported application bundle; update it with Homebrew"; continue }
                if paths.allSatisfy({ bundleMatches($0, version: target) }) {
                    report.skipped[token] = "The app already has the listed version; check Homebrew's installation record"
                    continue
                }
                var item = AppUpdate(token: token, name: (info["name"] as? [String])?.first ?? token,
                    installedVersions: installed.sorted(), targetVersion: target, appPaths: paths, bundleIDs: [:], identities: [:],
                    definition: definition(info), brew: brew, brewIdentity: executableIdentity(brew))
                let sha = info["sha256"] as? String ?? ""
                if target == "latest" || sha.count != 64 || !sha.allSatisfy({ $0.isHexDigit }) {
                    item.blocked = "This update has no fixed version or checksum; update it with Homebrew"
                }
                if row["pinned"] as? Bool == true { item.blocked = "This cask is pinned in Homebrew" }
                for path in paths {
                    guard let app = AppUninstaller.read(path), let id = app.bundleID, app.version != nil,
                          let identity = AppReviewIdentity.capture(path) else {
                        item.blocked = "Could not verify the installed app; check it in Homebrew"
                        continue
                    }
                    item.identities[path] = identity
                    item.bundleIDs[path] = id
                    if !installed.contains(where: { bundleMatches(path, version: $0) }) {
                        item.blocked = "The app version differs from Homebrew's installation record; check it in Homebrew"
                    }
                    if id.hasPrefix("dev.thermo.") { item.blocked = "Update Thermo from its own update settings" }
                }
                if AppUninstaller.runningProcess(in: paths, processes: table) != nil { item.blocked = "Quit this app before updating it" }
                if item.definition.isEmpty || item.brewIdentity == nil { item.blocked = "Could not verify Homebrew; check it before updating" }
                report.items.append(item)
            }
        } catch { report.issues.append(error.localizedDescription) }
        return report
    }

    public static func install(_ reviewed: AppUpdate, home: String = NSHomeDirectory(), runner: Runner? = nil,
                               processes: (() -> ProcessTable)? = nil) -> AppUpdateResult {
        let command = runner ?? run
        var result = AppUpdateResult(token: reviewed.token, outcome: "failed", message: "Update changed after review; check and review it again")
        let operationID = UUID().uuidString
        defer {
            OperationJournal.record(OperationRecord(id: operationID, feature: "apps", action: "update", subject: reviewed.name,
                outcome: result.outcome == "succeeded" ? "succeeded" : result.outcome == "unconfirmed" ? "partial" : "failed",
                items: [.init(target: reviewed.token, status: result.outcome == "succeeded" ? "done" : result.outcome == "unconfirmed" ? "partial" : "failed",
                              detail: reviewed.installedVersions.joined(separator: ", ") + " → " + reviewed.targetVersion + ": " + result.message)]), home: home)
        }
        guard reviewed.blocked == nil, validToken(reviewed.token), !reviewed.appPaths.isEmpty else { return result }
        let current = scan(brew: reviewed.brew, home: home, runner: command, processes: processes?())
        guard let item = current.items.first(where: { $0.token == reviewed.token }) else { return result }
        if let why = item.blocked { result.message = why; return result }
        guard item.definition == reviewed.definition, item.installedVersions == reviewed.installedVersions,
              item.targetVersion == reviewed.targetVersion, item.appPaths == reviewed.appPaths,
              item.identities == reviewed.identities, item.bundleIDs == reviewed.bundleIDs,
              item.brewIdentity == reviewed.brewIdentity else { return result }
        OperationJournal.record(OperationRecord(id: operationID, feature: "apps", action: "update", subject: item.name,
            outcome: "partial", items: [.init(target: item.token, status: "partial", detail: "The update started; its result has not been verified")]), home: home)
        let updated = command(item.brew, ["upgrade", "--cask", "--greedy", "--no-ask", "--no-quit", "--require-sha", "--skip-cask-deps", item.token], 600)
        // Always read back, including timeouts and failed installers: a change may have happened.
        result.outcome = "unconfirmed"
        result.message = "Update could not be confirmed; check Homebrew and the installed app before retrying"
        do {
            let after = try json(command(item.brew, ["info", "--cask", "--json=v2", item.token], 60))
            let matching = (after["casks"] as? [[String: Any]] ?? []).filter { ($0["full_token"] as? String ?? $0["token"] as? String) == item.token }
            guard matching.count == 1, matching[0]["installed"] as? String == item.targetVersion else { return result }
            for path in item.appPaths {
                guard let app = AppUninstaller.read(path), let version = app.version,
                      app.bundleID == item.bundleIDs[path], bundleMatches(path, version: item.targetVersion),
                      AppReviewIdentity.capture(path) != nil else { return result }
                result.versions[path] = version
            }
            if updated.status == 0, !updated.timedOut, !updated.cancelled {
                result.outcome = "succeeded"
                result.message = "Updated version verified in Homebrew and the app bundle"
            }
        } catch { return result }
        return result
    }
}
