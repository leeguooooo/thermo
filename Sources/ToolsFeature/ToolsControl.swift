import AgentCore
import Foundation
import HotkeyCore
import ThermoL10n
import ToolsControlAPI

/// `thermo screen`, `thermo awdl` and `thermo keep-awake` act on the same models as the visible
/// controls. A tool that is switched off refuses everything but its status.
@MainActor final class ToolsControl {
    private static let reads = ["screen.status", "awdl.status", "keep-awake.status"]
    private static let writes = ["screen.start", "screen.stop", "screen.duration", "screen.shortcut", "screen.clear-shortcut",
                                 "awdl.on", "awdl.off", "keep-awake.start", "keep-awake.stop"]
    static func handles(_ action: String) -> Bool { reads.contains(action) || writes.contains(action) }
    static func tool(_ action: String) -> ShellTool? {
        action.hasPrefix("screen.") ? .cleanScreen : action.hasPrefix("awdl.") ? .lowLatency : action.hasPrefix("keep-awake.") ? .keepAwake : nil
    }

    private let defaults: UserDefaults
    private let screen: CleanScreenModel
    private let idleAwake: IdleAwakeModel
    private let shortcut: @MainActor () -> CleanScreenShortcutModel
    private let network: @MainActor () -> AWDLModel
    private let enabled: (ShellTool) -> Bool
    private var mutating = false
    init(defaults: UserDefaults = .standard, screen: CleanScreenModel? = nil, idleAwake: IdleAwakeModel? = nil,
         shortcut: (@MainActor () -> CleanScreenShortcutModel)? = nil, network: (@MainActor () -> AWDLModel)? = nil,
         enabled: @escaping (ShellTool) -> Bool) {
        self.defaults = defaults; self.screen = screen ?? .shared; self.idleAwake = idleAwake ?? .shared
        self.shortcut = shortcut ?? { .shared }; self.network = network ?? { .shared }; self.enabled = enabled
    }

    func handle(_ request: AppControlRequest) async -> AppControlResponse {
        func result(_ values: [String:String] = [:], _ issue: String? = nil) -> AppControlResponse {
            .init(request: request, succeeded: issue == nil, values: values, issue: issue)
        }
        let action = request.action
        guard Self.handles(action), let tool = Self.tool(action) else { return result([:], "Unsupported App control operation.") }
        if Self.writes.contains(action), !enabled(tool) {
            return result([:], "\(tool.manifest.name) is switched off. Enable it in Thermo’s Feature Center before using it.")
        }
        guard request.arguments.keys.allSatisfy({ action == "keep-awake.start" ? ["mode","seconds","duration"].contains($0) : action == "awdl.on" ? $0 == "seconds" : ["screen.start","screen.duration"].contains(action) ? $0 == "duration" : action == "screen.shortcut" ? ["key-code","modifiers","key-label"].contains($0) : false }) else { return result([:], "Unexpected operation arguments.") }
        let screen = self.screen
        var idleMode: IdleAwakeMode?
        var idleSeconds: Double?
        if action == "keep-awake.start" {
            guard let raw = request.arguments["mode"], let mode = IdleAwakeMode(rawValue: raw) else { return result([:], "An explicit display, tasks or both mode is required.") }
            idleMode = mode
            if let duration = request.arguments["duration"] {
                guard duration == "manual", request.arguments["seconds"] == nil else { return result([:], "Use a timed duration or manual, not both.") }
            } else {
                guard let raw = request.arguments["seconds"], let seconds = Int(raw), (1...604800).contains(seconds) else { return result([:], "An explicit duration of 1…604800 seconds or manual is required.") }
                idleSeconds = Double(seconds)
            }
        }
        var duration: CleanScreenDuration?
        var binding: CleanScreenKeyBinding?
        if action == "screen.start" || action == "screen.duration" {
            if action == "screen.duration", request.arguments["duration"] == nil { return result([:], "An explicit duration is required.") }
            let saved = defaults.string(forKey:CleanScreenDuration.preferenceKey).flatMap(CleanScreenDuration.init(rawValue:)) ?? .twoMinutes
            guard let selected = CleanScreenDuration(rawValue:request.arguments["duration"] ?? saved.rawValue) else { return result([:], "Invalid screen duration.") }; duration = selected
        }
        if action == "screen.shortcut" {
            guard let key = UInt32(request.arguments["key-code"] ?? ""), let modifiers = UInt32(request.arguments["modifiers"] ?? ""), let label = request.arguments["key-label"] else { return result([:], "Invalid shortcut fields.") }
            let candidate = CleanScreenKeyBinding(keyCode: key, modifiers: modifiers, keyLabel: label)
            guard candidate.valid else { return result([:], "Shortcut requires a supported key and at least two modifiers including Command, Control or Option.") }; binding = candidate
        }
        if action == "awdl.on" {
            guard let seconds = Int(request.arguments["seconds"] ?? "300"), (60...3600).contains(seconds) else { return result([:], "AWDL duration must be 60…3600 seconds.") }
        }
        if request.dryRun {
            if action.hasPrefix("keep-awake.") {
                return result(["action":action,"dryRun":"true","changesMade":"false","requiresRunningApp":"true","requiresHelper":"false"])
            }
            screen.refreshPermission()
            return result(["action":action,"dryRun":"true","changesMade":"false","accessibility":String(screen.hasAccessibility),"requiresRunningApp":"true"])
        }
        let writes = Self.writes.contains(action)
        if writes {
            guard !mutating else { return result([:], "Another App control mutation is in progress. Query status; do not retry an uncertain action.") }
            mutating = true
        }
        defer { if writes { mutating = false } }
        switch action {
        case "keep-awake.start", "keep-awake.stop", "keep-awake.status":
            if action == "keep-awake.start", let idleMode { idleAwake.start(mode: idleMode, seconds: idleSeconds) }
            if action == "keep-awake.stop" { idleAwake.stop() }
            let values = idleAwake.controlValues()
            if action == "keep-awake.start", let issue = idleAwake.issue { return result(values, issue) }
            if action == "keep-awake.start", values["phase"] != "active" { return result(values, values["issue"] ?? "Idle awake did not become active. Query status before another action.") }
            if values["phase"] == "ending" { return result(values, values["issue"] ?? "Idle-awake state is unconfirmed.") }
            return result(values)
        case "awdl.on", "awdl.off", "awdl.status":
            let network = network()
            guard !network.busy else { return result([:], "An AWDL operation is already in progress.") }
            network.refresh()
            guard await wait(seconds: 8, until: { !network.busy }) else { return result([:], "AWDL state is unconfirmed.") }
            if action == "awdl.on" {
                guard let seconds = Int(request.arguments["seconds"] ?? "300"), (60...3600).contains(seconds), network.canStart else { return result([:], "AWDL start is unavailable or duration is invalid.") }
                network.start(seconds: seconds)
            }
            if action == "awdl.off" {
                guard network.canStop else { return result([:], "This App does not own an AWDL session it can stop.") }
                network.stop()
            }
            guard await wait(seconds: 15, until: { !network.busy }), let state = network.state else { return result([:], "AWDL result is unconfirmed; query state before another action.") }
            let confirmed = action == "awdl.status" || (action == "awdl.on" ? state.phase == .active && state.ownedByCaller : state.phase == .idle)
            return result(["phase":state.phase.rawValue,"ownedByApp":String(state.ownedByCaller)], network.issue ?? (confirmed ? nil : "AWDL state did not confirm the requested change."))
        case "screen.start":
            if screen.active, screen.session?.duration != duration { return result(screenState(), "A different screen session is already active; stop it explicitly before changing duration.") }
            if request.arguments["duration"] != nil { defaults.set(duration!.rawValue,forKey:CleanScreenDuration.preferenceKey) }
            screen.start(duration!)
            return result(screenState(), screen.active ? nil : screen.issue ?? "Clean Screen did not start.")
        case "screen.stop": screen.stop(); return result(screenState())
        case "screen.duration": defaults.set(duration!.rawValue,forKey:CleanScreenDuration.preferenceKey); return result(screenState())
        case "screen.shortcut", "screen.clear-shortcut":
            let shortcut = shortcut()
            shortcut.apply(action == "screen.clear-shortcut" ? nil : binding)
            return result(screenState(), shortcut.issue)
        default: return result(screenState())
        }
    }

    /// Fields for the app control `status` reply.
    func statusValues() -> [String: String] {
        let awake = idleAwake.inspect()
        return ["screenActive": String(screen.active), "keepAwakeRequested": String(awake.requested), "keepAwakePhase": awake.phase.rawValue]
    }

    private func screenState() -> [String:String] {
        let model = screen; model.refreshPermission()
        let shortcut = shortcut()
        var state = ["active":String(model.active),"accessibility":String(model.hasAccessibility),"shortcut":shortcut.binding?.label ?? "", "shortcutUncertain":String(shortcut.uncertain),"savedDuration":defaults.string(forKey:CleanScreenDuration.preferenceKey).flatMap(CleanScreenDuration.init(rawValue:))?.rawValue ?? CleanScreenDuration.twoMinutes.rawValue]
        if let session = model.session { state["duration"] = session.duration.rawValue; state["remainingSeconds"] = session.remaining(ProcessInfo.processInfo.systemUptime).map(String.init(describing:)) ?? "manual" }
        if let issue = model.issue { state["issue"] = issue }
        if !enabled(.cleanScreen) { state["featureEnabled"] = "false" }
        return state
    }
    private func wait(seconds: Double, until done: @escaping @MainActor () -> Bool) async -> Bool {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if done() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        } while ProcessInfo.processInfo.systemUptime < end
        return false
    }
}
