import AgentCore
import Foundation

struct CameraCommand {
    let app: App
    func run(_ rest: [String]) throws {
        let sub = rest.first ?? "inspect"
        guard ["inspect", "status", "on", "off"].contains(sub), rest.count <= 1 else { throw CLIError("Run thermo camera --help.") }
        if sub != "inspect" { try AppControlCommand(app: app).run(command: "camera", rest: [sub]); return }
        guard Set(app.args.options.keys).isSubset(of: ["limit"]), app.args.flags.isSubset(of: ["json", "no-color"]) else {
            throw CLIError("camera inspect accepts only --limit, --json and --no-color; it never changes preferences")
        }
        let report = CameraReport(observation: CameraActivity.read(), source: "liveInspection", limit: try Self.limit(app.args.options["limit"]))
        print(app.args.has("json") ? Export.json(report) : Self.text(report))
        if report.complete != true || report.fresh != true { throw CLIError("Camera activity could not be fully verified; partial metadata was preserved.", exitCode: 3) }
    }
    static func limit(_ raw: String?) throws -> Int {
        guard let value = Int(raw ?? "64"), (1...256).contains(value) else { throw CLIError("--limit must be 1…256") }
        return value
    }
    static func text(_ report: CameraReport) -> String {
        var lines = ["Camera: " + report.state, "Scope: system-reported video inputs; application attribution unavailable"]
        if let enabled = report.enabled { lines.append("Alerts enabled: \(enabled)") }
        if let coverage = report.eventCoverage { lines.append("Event registration: " + coverage) }
        if let access = report.notificationAccess { lines.append("Notifications: " + access) }
        if let issue = report.notificationIssue { lines.append("Notification issue: " + String(reflecting: issue)) }
        if let sampled = report.sampled { lines.append("Observed: " + ISO8601DateFormatter().string(from: sampled)) }
        lines.append("Reported inputs: \(report.totalDevices) (shown \(report.devices.count))")
        for device in report.devices { lines.append("  \(String(reflecting: device.name)): \(device.active ? "active" : "idle")") }
        for issue in report.issues { lines.append("Issue: " + String(reflecting: issue)) }
        if report.state == "noDevices" { lines.append("An empty inventory does not establish that every camera is visible.") }
        if report.outputTruncated { lines.append("Output limited; totals refer to the full observation.") }
        return lines.joined(separator: "\n")
    }
}
