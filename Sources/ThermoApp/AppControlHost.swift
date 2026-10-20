import AgentCore
import AppKit
import Foundation
import ThermoKit

/// App-owned operations execute in the same models as their visible controls.
/// The socket is same-user only; requests are bounded and never interpreted as shell commands.
@MainActor final class AppControlHost {
    static let shared = AppControlHost()
    private let defaults: UserDefaults
    private let screen: CleanScreenModel
    private let idleAwake: IdleAwakeModel
    private let audioInput: MicrophoneAlerts
    private let camera: CameraAlerts
    private let configureCamera: @MainActor (Bool) -> Void
    private let configureAudioInput: @MainActor (Bool) -> Void
    private let requestAudioNotifications: @MainActor () -> Void
    private let audioNotificationState: @MainActor () async -> String
    init(defaults: UserDefaults = .standard, screen: CleanScreenModel? = nil, idleAwake: IdleAwakeModel? = nil,
         audioInput: MicrophoneAlerts? = nil, configureAudioInput: (@MainActor (Bool) -> Void)? = nil,
         requestAudioNotifications: (@MainActor () -> Void)? = nil, audioNotificationState: (@MainActor () async -> String)? = nil,
         camera: CameraAlerts? = nil, configureCamera: (@MainActor (Bool) -> Void)? = nil) {
        self.defaults = defaults; self.screen = screen ?? .shared; self.idleAwake = idleAwake ?? .shared
        let input = audioInput ?? .shared
        self.audioInput = input
        let video = camera ?? .shared
        self.camera = video; self.configureCamera = configureCamera ?? { video.configure($0) }
        self.configureAudioInput = configureAudioInput ?? { input.configure($0) }
        self.requestAudioNotifications = requestAudioNotifications ?? { NotificationAccess.shared.request() }
        self.audioNotificationState = audioNotificationState ?? {
            String(describing: await NotificationAccess.shared.readCurrentState())
        }
    }
    private var server: AppControlServer?
    private let integration = AgentAccess()
    private var seen = Set<UUID>()
    private var mutating = false
    private(set) var issue: String?
    func start() {
        guard server == nil else { return }
        do {
            let trust = try LocalControlPeerTrust(team:CodeSignature.teamIdentifier(),developmentExecutable:URL(fileURLWithPath:integration.cli))
            server = try AppControlServer(authorize:{ trust.accepts(auditToken:$0) }) { request, reply in
                Task { @MainActor in reply(await self.handle(request)) }
            }
        } catch { issue = error.localizedDescription }
    }
    func handle(_ request: AppControlRequest) async -> AppControlResponse {
        func result(_ values: [String:String] = [:], _ issue: String? = nil, audioInput: AudioInputReport? = nil, camera: CameraReport? = nil) -> AppControlResponse {
            .init(request: request, succeeded: issue == nil, values: values, issue: issue, audioInput: audioInput, camera: camera)
        }
        guard !seen.contains(request.id) else { return result([:], "This request ID was already received. Query status; mutations are never replayed.") }
        // Bounded process-lifetime replay guard. Do not evict IDs and permit later replay.
        guard seen.count < 100_000 else { return result([:], "Control request limit reached; restart Thermo when idle.") }
        seen.insert(request.id)
        let action = request.action
        let reads = ["camera.status","audio-input.status","status","screen.status","login.status","updates.status","helper.status","permissions.status","integration.status","awdl.status","keep-awake.status"]
        let writes = ["camera.on","camera.off","audio-input.on","audio-input.off","audio-input.mute","audio-input.unmute","screen.start","screen.stop","screen.duration","screen.shortcut","screen.clear-shortcut","login.on","login.off","updates.on","updates.off","updates.check","helper.install","helper.uninstall","permissions.notifications","permissions.accessibility","permissions.login","integration.link","integration.claude","integration.codex","awdl.on","awdl.off","keep-awake.start","keep-awake.stop"]
        guard reads.contains(action) || writes.contains(action) else { return result([:], "Unsupported App control operation.") }
        guard request.arguments.keys.allSatisfy({ ["audio-input.mute","audio-input.unmute"].contains(action) ? $0 == "app" : action == "keep-awake.start" ? ["mode","seconds","duration"].contains($0) : action == "awdl.on" ? $0 == "seconds" : ["screen.start","screen.duration"].contains(action) ? $0 == "duration" : action == "screen.shortcut" ? ["key-code","modifiers","key-label"].contains($0) : false }) else { return result([:], "Unexpected operation arguments.") }
        if ["audio-input.mute", "audio-input.unmute"].contains(action) {
            guard let key = request.arguments["app"], !key.isEmpty, key.utf8.count <= 4096,
                  !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                return result([:], "An explicit valid App key is required.")
            }
            guard audioInput.knownApps[key] != nil || audioInput.muted.contains(key) else {
                return result([:], "Unknown App key. Use an App-observed or already muted key; do not guess a name.",
                              audioInput: audioInput.controlReport(notificationAccess: "notQueried"))
            }
        }
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
            if action.hasPrefix("camera.") {
                return result(["action":action,"dryRun":"true","changesMade":"false","recordsVideo":"false"],
                              camera: camera.controlReport(notificationAccess: "notQueried"))
            }
            if action.hasPrefix("audio-input.") {
                return result(["action":action,"dryRun":"true","changesMade":"false","requiresRunningApp":"true","recordsAudio":"false"],
                              audioInput: audioInput.controlReport(notificationAccess: "notQueried"))
            }
            if action.hasPrefix("keep-awake.") {
                return result(["action":action,"dryRun":"true","changesMade":"false","requiresRunningApp":"true","requiresHelper":"false"])
            }
            screen.refreshPermission()
            return result(["action":action,"dryRun":"true","changesMade":"false","accessibility":String(screen.hasAccessibility),"requiresRunningApp":"true"])
        }
        if writes.contains(action) {
            guard !mutating else { return result([:], "Another App control mutation is in progress. Query status; do not retry an uncertain action.") }
            mutating = true
        }
        defer { if writes.contains(action) { mutating = false } }
        switch action {
        case "camera.status", "camera.on", "camera.off":
            if action != "camera.status" {
                let on = action == "camera.on"
                defaults.set(on, forKey: CameraAlerts.enabledKey); configureCamera(on)
                if on { requestAudioNotifications() }
            }
            let access = await audioNotificationState()
            let report = camera.controlReport(notificationAccess: access)
            return result(["enabled":String(camera.enabled),"state":report.state,"recordsVideo":"false"], camera: report)
        case "audio-input.status", "audio-input.on", "audio-input.off", "audio-input.mute", "audio-input.unmute":
            if action == "audio-input.on" || action == "audio-input.off" {
                let on = action == "audio-input.on"
                defaults.set(on, forKey: MicrophoneAlerts.enabledKey)
                configureAudioInput(on)
                if on { requestAudioNotifications() }
            } else if let key = request.arguments["app"] {
                audioInput.setMuted(key, action == "audio-input.mute")
            }
            let access = await audioNotificationState()
            let report = audioInput.controlReport(notificationAccess: access)
            return result(["enabled":String(audioInput.enabled),"state":report.state,"recordsAudio":"false"], audioInput: report)
        case "keep-awake.start", "keep-awake.stop", "keep-awake.status":
            if action == "keep-awake.start", let idleMode { idleAwake.start(mode: idleMode, seconds: idleSeconds) }
            if action == "keep-awake.stop" { idleAwake.stop() }
            let values = idleAwake.controlValues()
            if action == "keep-awake.start", let issue = idleAwake.issue { return result(values, issue) }
            if action == "keep-awake.start", values["phase"] != "active" { return result(values, values["issue"] ?? "Idle awake did not become active. Query status before another action.") }
            if values["phase"] == "ending" { return result(values, values["issue"] ?? "Idle-awake state is unconfirmed.") }
            return result(values)
        case "awdl.on", "awdl.off", "awdl.status":
            let network = AWDLModel.shared
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
            let shortcut = CleanScreenShortcutModel.shared
            shortcut.apply(action == "screen.clear-shortcut" ? nil : binding)
            return result(screenState(), shortcut.issue)
        case "screen.status": return result(screenState())
        case "login.on", "login.off", "login.status":
            let login = LoginItemAccess.shared
            if action != "login.status" { login.setRequested(action == "login.on") } else { login.refresh() }
            let values = ["state":String(describing:login.state),"requested":String(login.requested)]
            if action == "login.on", login.state != .enabled { return result(values, login.error ?? "Login registration needs approval or was not confirmed.") }
            if action == "login.off", login.state != .off { return result(values, login.error ?? "Login removal was not confirmed.") }
            return result(values, login.error)
        case "updates.on", "updates.off", "updates.check", "updates.status":
            let updates = AppModels.shared.updates
            if action != "updates.status", !updates.enabled { return result(["enabled":"false"], "This App has no configured update feed.") }
            if action == "updates.on" || action == "updates.off" { updates.automaticallyChecks = action == "updates.on" }
            if action == "updates.check" {
                guard updates.canCheck else { return result([:], "Updater cannot check right now.") }
                updates.checkForUpdates()
            }
            return result(["enabled":String(updates.enabled),"automaticallyChecks":String(updates.automaticallyChecks),"canCheck":String(updates.canCheck),"outcome":action == "updates.check" ? "interactiveCheckStarted" : "observed", "installationConfirmed":"false"])
        case "helper.install", "helper.uninstall", "helper.status":
            let monitor = AppModels.shared.monitor
            guard !monitor.helperBusy else { return result([:], "A helper operation is already running.") }
            var removalFinished = false
            if action == "helper.install" { monitor.installHelper() }
            if action == "helper.uninstall" { monitor.uninstallHelper(finished: { removalFinished = true }) }
            if action != "helper.status" {
                guard await wait(seconds: 270, until: { !monitor.helperBusy && !monitor.settingUp }) else { return result([:], "Helper result is unconfirmed; inspect helper status before another action.") }
            }
            if action == "helper.uninstall" {
                guard removalFinished else { return result([:], "Helper removal did not execute or its completion is unknown.") }
                return result(["outcome":monitor.lastError == nil ? "removedWithRecoveryConfirmed" : "failed"], monitor.lastError)
            }
            let client = HelperClient(); defer { client.reset() }
            let version = try? await client.version()
            if action == "helper.install", version != HelperConstants.version {
                return result(["version":version ?? "unknown"], monitor.lastError ?? "Installed helper did not confirm the expected version.")
            }
            return result(["state":String(describing:monitor.helperState),"busy":String(monitor.helperBusy),"version":version ?? "unknown"], action == "helper.status" ? nil : monitor.lastError)
        case "permissions.accessibility": screen.openAccessibilitySettings(); return result(["outcome":"settingsOpened","permissionGranted":"unknown"])
        case "permissions.login": LoginItemAccess.shared.openSettings(); return result(["outcome":"settingsOpened","permissionGranted":"unknown"])
        case "permissions.notifications":
            let access = NotificationAccess.shared; access.request()
            guard await wait(seconds: 15, until: { !access.requesting }) else { return result([:], "Notification permission is awaiting user response; query permissions status.") }
            access.refresh(); try? await Task.sleep(nanoseconds: 100_000_000)
            let granted = access.state == .allowed || access.state == .bannersDisabled
            return result(["notifications":String(describing:access.state),"permissionGranted":String(granted)], access.error ?? (granted ? nil : "Notification permission is not confirmed as granted."))
        case "integration.link", "integration.claude", "integration.codex", "integration.status":
            if action == "integration.link" { integration.linkCLI() }
            else if action == "integration.claude" { integration.addToClaude() }
            else if action == "integration.codex" { integration.addToCodex() }
            else { integration.refresh() }
            guard await wait(seconds: 270, until: { !self.integration.checking && self.integration.busy == nil }) else { return result([:], "Integration result is unconfirmed; query integration status.") }
            let values = ["cliLinked":String(integration.cliLinked),"claude":String(describing:integration.claude),"codex":String(describing:integration.codex)]
            if action == "integration.link", !integration.cliLinked { return result(values, integration.linkProblem ?? "CLI link not confirmed.") }
            if action == "integration.claude", integration.claude != .added { return result(values, integration.message ?? "Claude integration not confirmed.") }
            if action == "integration.codex", integration.codex != .added { return result(values, integration.message ?? "Codex integration not confirmed.") }
            return result(values)
        case "permissions.status":
            let notifications = NotificationAccess.shared; notifications.refresh(); screen.refreshPermission()
            try? await Task.sleep(nanoseconds: 100_000_000)
            return result(["accessibility":String(screen.hasAccessibility),"notifications":String(describing:notifications.state)])
        default:
            let awake = idleAwake.inspect()
            return result(["appVersion":AppInfo.version,"controlProtocol":"1","busy":String(mutating),"screenActive":String(screen.active),
                           "keepAwakeRequested":String(awake.requested),"keepAwakePhase":awake.phase.rawValue,
                           "windowVisible":String(AppModels.shared.monitor.windowOpen),
                           "menuPanelOpen":String(AppModels.shared.monitor.popoverOpen),
                           "menuPanelSampling":String(PanelModel.shared.samplingActive),
                           "pulseSampling":String(SystemPulse.shared.samplingActive),
                           "pulseHolders":String(SystemPulse.shared.holderCount)])
        }
    }
    private func screenState() -> [String:String] {
        let model = screen; model.refreshPermission()
        let shortcut = CleanScreenShortcutModel.shared
        var state = ["active":String(model.active),"accessibility":String(model.hasAccessibility),"shortcut":shortcut.binding?.label ?? "", "shortcutUncertain":String(shortcut.uncertain),"savedDuration":defaults.string(forKey:CleanScreenDuration.preferenceKey).flatMap(CleanScreenDuration.init(rawValue:))?.rawValue ?? CleanScreenDuration.twoMinutes.rawValue]
        if let session = model.session { state["duration"] = session.duration.rawValue; state["remainingSeconds"] = session.remaining(ProcessInfo.processInfo.systemUptime).map(String.init(describing:)) ?? "manual" }
        if let issue = model.issue { state["issue"] = issue }
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
