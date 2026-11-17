import ApplicationServices
import ModuleKit
import ThermoUI
import AgentCore
import AppKit
import Foundation
import ThermoKit
import ToolsControlAPI

/// App-owned operations execute in the same models as their visible controls.
/// The socket is same-user only; requests are bounded and never interpreted as shell commands.
@MainActor final class AppControlHost {
    static let shared = AppControlHost()
    typealias CaptureHandler = @MainActor (AppControlRequest) async->AppControlResponse
    private let captureHandler:CaptureHandler
    private let tools: @MainActor () -> any ToolsApplicationAccess
    init(capture:CaptureHandler? = nil, tools: (@MainActor () -> any ToolsApplicationAccess)? = nil) {
        self.captureHandler=capture ?? CaptureControlBridge.handle; self.tools = tools ?? { ShellTools.access }
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
        func result(_ values: [String:String] = [:], _ issue: String? = nil) -> AppControlResponse {
            .init(request: request, succeeded: issue == nil, values: values, issue: issue)
        }
        guard !seen.contains(request.id) else { return result([:], "This request ID was already received. Query status; mutations are never replayed.") }
        // Bounded process-lifetime replay guard. Do not evict IDs and permit later replay.
        guard seen.count < 100_000 else { return result([:], "Control request limit reached; restart Thermo when idle.") }
        seen.insert(request.id)
        let action = request.action
        if action == "modules.run" { return await ModuleCommandHost.handle(request) }
        if action.hasPrefix("search."), action != "search.giveBackCommandSpace", !ModuleCenter.shared.isOn(BuiltinModuleManifests.search.id) {
            return result([:], "Search apps and files is switched off. Enable it in Thermo Settings before using it.")
        }
        if action.hasPrefix("capture."){return await captureHandler(request)}
        // Clean Screen, low latency and keep awake belong to their own features.
        let tools = self.tools()
        if tools.handles(action) { return await tools.handle(request) }
        let reads = ["status","login.status","updates.status","helper.status","permissions.status","integration.status"]
        let writes = ["login.on","login.off","updates.on","updates.off","updates.check","helper.install","helper.uninstall","permissions.notifications","permissions.accessibility","permissions.login","integration.link","integration.claude","integration.codex","search.show","search.settings","search.useCommandSpace","search.giveBackCommandSpace"]
        guard reads.contains(action) || writes.contains(action) else { return result([:], "Unsupported App control operation.") }
        guard request.arguments.isEmpty else { return result([:], "Unexpected operation arguments.") }
        if request.dryRun {
            return result(["action":action,"dryRun":"true","changesMade":"false","accessibility":String(AXIsProcessTrusted()),"requiresRunningApp":"true"])
        }
        if writes.contains(action) {
            guard !mutating else { return result([:], "Another App control mutation is in progress. Query status; do not retry an uncertain action.") }
            mutating = true
        }
        defer { if writes.contains(action) { mutating = false } }
        switch action {
        case "search.show", "search.settings":
            let shown=SearchHost.show(settings:action == "search.settings")
            return result(["action":action,"windowVisible":String(shown)],shown ? nil:"Search is unavailable while its feature is stopping.")
        case "search.useCommandSpace", "search.giveBackCommandSpace":
            let taking=action == "search.useCommandSpace"
            let state=taking ? SearchHost.access.takeOverSpotlight():SearchHost.access.giveBackSpotlight()
            let values=["action":action,"shortcut":state.label,"spotlightReleased":String(state.spotlightReleased)]
            return result(values,state.confirmed ? nil:state.issue ?? "The ⌘Space change was not confirmed. Check Search settings.")
        case "login.on", "login.off", "login.status":
            let login = LoginItemAccess.shared
            if action != "login.status" { login.setRequested(action == "login.on") } else { login.refresh() }
            let values = ["state":String(describing:login.state),"requested":String(login.requested)]
            if action == "login.on", login.state != .enabled { return result(values, login.error ?? "Login registration needs approval or was not confirmed.") }
            if action == "login.off", login.state != .off { return result(values, login.error ?? "Login removal was not confirmed.") }
            return result(values, login.error)
        case "updates.on", "updates.off", "updates.check", "updates.status":
            let updates = ShellState.shared.updates
            if action != "updates.status", !updates.enabled { return result(["enabled":"false"], "This App has no configured update feed.") }
            if action == "updates.on" || action == "updates.off" { updates.automaticallyChecks = action == "updates.on" }
            if action == "updates.check" {
                guard updates.canCheck else { return result([:], "Updater cannot check right now.") }
                updates.checkForUpdates()
            }
            return result(["enabled":String(updates.enabled),"automaticallyChecks":String(updates.automaticallyChecks),"canCheck":String(updates.canCheck),"outcome":action == "updates.check" ? "interactiveCheckStarted" : "observed", "installationConfirmed":"false"])
        case "helper.install", "helper.uninstall", "helper.status":
            let helper = ShellState.shared.services.helper
            guard !helper.latest.busy else { return result([:], "A helper operation is already running.") }
            var removalFinished = false
            if action == "helper.install" { helper.install() }
            if action == "helper.uninstall" { helper.uninstall(finished: { removalFinished = true }) }
            if action != "helper.status" {
                guard await wait(seconds: 270, until: { !helper.latest.busy && !helper.latest.settingUp }) else { return result([:], "Helper result is unconfirmed; inspect helper status before another action.") }
            }
            if action == "helper.uninstall" {
                guard removalFinished else { return result([:], "Helper removal did not execute or its completion is unknown.") }
                return result(["outcome":helper.latest.error == nil ? "removedWithRecoveryConfirmed" : "failed"], helper.latest.error)
            }
            let client = HelperClient(); defer { client.reset() }
            let version = try? await client.version()
            if action == "helper.install", version != HelperConstants.version {
                return result(["version":version ?? "unknown"], helper.latest.error ?? "Installed helper did not confirm the expected version.")
            }
            return result(["state":String(describing:helper.latest.phase),"busy":String(helper.latest.busy),"version":version ?? "unknown"], action == "helper.status" ? nil : helper.latest.error)
        case "permissions.accessibility":
            NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            return result(["outcome":"settingsOpened","permissionGranted":"unknown"])
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
            let notifications = NotificationAccess.shared; notifications.refresh()
            try? await Task.sleep(nanoseconds: 100_000_000)
            return result(["accessibility":String(AXIsProcessTrusted()),"notifications":String(describing:notifications.state)])
        default:
            let store=ShellState.shared.nativeFeatures,performance=store.status(BuiltinModuleManifests.performance.id)
            return result(tools.statusValues.merging(["appVersion":AppInfo.version,"controlProtocol":"1","busy":String(mutating),
                           "windowVisible":String(store.hostPresentation.windowVisible),
                           "mainPage":String(describing: MainWindow.state.page),
                           "cpuPageSampling":String(performance.readers["cpu"]?.sampling ?? false),
                           "gpuPageSampling":String(performance.readers["gpu"]?.sampling ?? false),
                           "memoryPageSampling":String(performance.readers["memory"]?.sampling ?? false),
                           "connectionsSampling":String(ShellState.shared.nativeFeatures.status(BuiltinModuleManifests.connections.id).sampling),
                           "menuPanelOpen":String(store.hostPresentation.menuPanelVisible),
                           "menuPanelSampling":String(performance.readers["panel"]?.sampling ?? false),
                           "pulseSampling":String(performance.readers["pulse"]?.sampling ?? false),
                           "pulseHolders":String(performance.readers["pulse"]?.holders ?? 0)]){$1})
        }
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
