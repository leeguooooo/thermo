import CleanKit
import Foundation

struct ActionReceipt: Encodable {
    let action: String
    let dryRun: Bool
    let outcome: String
    let message: String
}

extension App {
    func approveAction(_ message: String) throws {
        if args.has("yes") { return }
        guard !args.has("json"), isatty(STDIN_FILENO) != 0 else { throw CLIError("Review --dry-run, then add --yes to execute.") }
        print(message + " [y/N] ", terminator: ""); fflush(stdout)
        guard ["y","yes"].contains(readLine()?.lowercased() ?? "") else { throw CLIError("Cancelled. Nothing changed.") }
    }
    func receipt(_ action: String, dryRun: Bool = false, outcome: String = "succeeded", message: String) {
        if args.has("json") { print(Export.json(ActionReceipt(action: action, dryRun: dryRun, outcome: outcome, message: message))) }
        else { print(message) }
    }
}

struct PrivacyCommand {
    let app: App
    func run(_ rest: [String], service: PrivacyToolsService = .init()) throws {
        let action = rest.first ?? "profiles"
        if action == "profiles" {
            guard rest.count <= 1 else { throw CLIError("usage: thermo privacy profiles") }
            let profiles = try service.discoverProfiles()
            if app.args.has("json") { print(Export.json(profiles)) }
            else { print(profiles.map { $0.name + " · " + $0.directory.path }.joined(separator: "\n")) }
            return
        }
        if action == "lookup" {
            guard rest.count == 1 else { throw CLIError("usage: thermo privacy lookup") }
            if app.args.has("dry-run") { app.receipt(action, dryRun: true, outcome: "planned", message: "Queries ipwho.is over HTTPS; sends the public IP, changes no settings."); return }
            let value = try TabsCommand(app: app).blocking { try await service.lookupExitLocation() }
            if app.args.has("json") { print(Export.json(value)) } else { print(value.country + " · " + value.timezone) }
            return
        }
        var timezone: String?
        if action == "timezone" {
            guard rest.count == 2, ["set","restore"].contains(rest[1]) else { throw CLIError("usage: thermo privacy timezone set --timezone ZONE | timezone restore") }
            if rest[1] == "set" {
                guard let value = app.args.options["timezone"], PrivacyToolsService.validTimezone(value) else { throw CLIError("Supply a known IANA timezone with --timezone.") }
                timezone = value
            } else if app.args.options["timezone"] != nil { throw CLIError("timezone restore does not accept --timezone") }
        } else {
            guard rest.count == 1, ["location","webrtc","cookies","restore-browser","environment","dns"].contains(action), app.args.options["timezone"] == nil else {
                throw CLIError("Unknown privacy action. Run thermo privacy --help.")
            }
        }
        let messages = [
            "location":"Block the default browser location permission; existing site grants may override it. Quit browsers first. Settings are backed up.",
            "webrtc":"Restrict WebRTC; calls and meetings may stop working. Quit browsers first. Settings are backed up.",
            "cookies":"Delete only mail.com cookies and sign out there. Quit browsers first. Sensitive cookie backups need manual recovery.",
            "restore-browser":"Restore the latest browser settings backup only if settings still match Thermo's changes. Quit browsers first.",
            "environment":"Remove only named Claude/Anthropic launchd variables. Values cannot be restored. Current processes and shell files stay unchanged.",
            "dns":"Flush DNS caches with macOS administrator approval. DNS servers and proxies stay unchanged.",
            "timezone":timezone.map { "Set the system timezone to \($0), retaining the previous timezone for restore. Administrator approval is required." } ?? "Restore the saved system timezone. Administrator approval is required."
        ]
        let message = messages[action]!
        if app.args.has("dry-run") { app.receipt(action, dryRun: true, outcome: "planned", message: message); return }
        try app.approveAction(message)
        let result: String
        switch action {
        case "location": result = try service.applyBrowser(.location)
        case "webrtc": result = try service.applyBrowser(.webRTC)
        case "cookies": result = try service.clearMailCookies()
        case "restore-browser": result = try service.restoreLatestBrowserChange()
        case "environment": result = try service.clearClaudeEnvironment()
        case "dns": result = try service.flushDNS()
        default: result = try timezone.map { try service.setTimezone($0) } ?? service.restoreTimezone()
        }
        app.receipt(action, message: result)
    }
}

struct ClaudeResetCommand {
    let app: App
    func run(_ rest: [String], service: ClaudeCleanup = .init()) throws {
        let action = rest.first ?? "list"
        switch action {
        case "list":
            guard rest.count <= 1 else { throw CLIError("usage: thermo claude-reset list") }
            let rows = service.scan()
            if app.args.has("json") { print(Export.json(rows)) }
            else { print(rows.map { $0.target.rawValue + " · " + $0.status.rawValue + " · " + $0.path + ($0.reason.map { " · " + $0 } ?? "") }.joined(separator: "\n")) }
        case "batches":
            guard rest.count == 1 else { throw CLIError("usage: thermo claude-reset batches") }
            let report = service.batchReport()
            print(Export.json(report))
            if !report.complete { throw CLIError("Claude backup inventory is incomplete; inspect issues.",exitCode:3) }
        case "run":
            let names = rest.dropFirst()
            let targets = names.compactMap(ClaudeResetTarget.init(rawValue:))
            guard !targets.isEmpty, targets.count == names.count, Set(targets).count == targets.count else {
                throw CLIError("Choose explicit, unique targets from claude-reset list. No all/default reset is provided.")
            }
            let selected = service.scan().filter { targets.contains($0.target) }
            guard !selected.contains(where: { a in selected.contains(where: { b in a.target != b.target && a.path.hasPrefix(b.path + "/") }) }) else {
                throw CLIError("Select full data or individual files, not both. Nothing reset.")
            }
            guard selected.allSatisfy({ $0.status == .available }) else {
                print(Export.json(selected)); throw CLIError("Some selected data is missing or blocked; nothing reset.")
            }
            if app.args.has("dry-run") { print(Export.json(selected)); return }
            try app.approveAction("Move the selected Claude data into a private recoverable backup? This can sign you out or remove local settings and conversations.")
            try emit(service.reset(selected))
        case "restore":
            guard rest.count == 2 else { throw CLIError("usage: thermo claude-reset restore UUID") }
            let batch = try service.loadBatch(id: rest[1])
            if app.args.has("dry-run") {
                let review = try service.reviewRestore(batchID:batch.id)
                print(Export.json(review))
                if !review.blocked.isEmpty { throw CLIError("Some restore entries are blocked; inspect the review.",exitCode:3) }
                return
            }
            try app.approveAction("Restore batch \(batch.id)? Existing destination data is preserved and active Claude sessions block restore.")
            try emit(service.restore(batchID: batch.id))
        default: throw CLIError("Run thermo claude-reset --help.")
        }
    }
    func emit(_ result: ClaudeResetResult) throws {
        print(Export.json(result))
        guard result.failed.isEmpty, !result.succeeded.isEmpty else { throw CLIError("Claude reset/restore was not complete; inspect the result.", exitCode: 3) }
    }
}
