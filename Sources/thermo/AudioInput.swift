import AgentCore
import Foundation

struct AudioInputCommand {
    let app: App
    func run(_ rest: [String]) throws {
        let sub = rest.first ?? "inspect"
        guard ["inspect", "status", "on", "off", "mute", "unmute"].contains(sub), rest.count <= 1 else {
            throw CLIError("Run thermo audio-input --help.")
        }
        if sub != "inspect" { try AppControlCommand(app: app).run(command: "audio-input", rest: [sub]); return }
        try Self.validateInspection(app.args)
        let limit = try Self.limit(app.args.options["limit"])
        let report = AudioInputReport(observation: AudioInputActivity.read(), source: "liveInspection", limit: limit)
        print(app.args.has("json") ? Export.json(report) : Self.text(report))
        if report.complete != true || report.fresh != true {
            throw CLIError("Audio input activity could not be fully verified; partial metadata was preserved.", exitCode: 3)
        }
    }
    static func validateInspection(_ args: Args) throws {
        guard Set(args.options.keys).isSubset(of: ["limit"]), args.flags.isSubset(of: ["json", "no-color"]) else {
            throw CLIError("audio-input inspect accepts only --limit, --json and --no-color; it never changes preferences")
        }
    }
    static func limit(_ raw: String?) throws -> Int {
        guard let value = Int(raw ?? "64"), (1...4096).contains(value) else { throw CLIError("--limit must be 1…4096") }
        return value
    }
    static func text(_ report: AudioInputReport) -> String {
        var lines = ["Audio input: " + report.state]
        if let enabled = report.enabled { lines.append("Alerts enabled: \(enabled)") }
        if let reading = report.reading { lines.append("Metadata read in flight: \(reading)") }
        if let coverage = report.eventCoverage { lines.append("Event registration: " + coverage) }
        if let access = report.notificationAccess { lines.append("Notifications: " + access) }
        if let issue = report.notificationIssue { lines.append("Notification issue: " + String(reflecting: issue)) }
        if let sampled = report.sampled { lines.append("Observed: " + ISO8601DateFormatter().string(from: sampled)) }
        lines.append("Input processes: \(report.totalClients) (shown \(report.clients.count))")
        for client in report.clients {
            // Reflection quotes/escapes control characters in process/device names and paths.
            lines.append("  \(String(reflecting: client.name)) · PID \(client.pid)")
            lines.append("    app key: \(String(reflecting: client.appKey))")
            for name in client.devices { lines.append("    input: " + String(reflecting: name)) }
        }
        if report.totalMutedApps > 0 {
            lines.append("Muted apps: \(report.totalMutedApps) (shown \(report.mutedApps.count))")
            for item in report.mutedApps { lines.append("  \(String(reflecting: item.name)): \(String(reflecting: item.key))") }
        }
        for issue in report.issues { lines.append("Issue: " + String(reflecting: issue)) }
        if report.outputTruncated { lines.append("Output limited; totals refer to the full observation. Inspect supports --limit for fresh process lists; App status and notification errors have separate output bounds.") }
        return lines.joined(separator: "\n")
    }
}
