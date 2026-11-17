import AgentCore
import ModuleKit
import NativeFeatureAPI

/// The menu bar tools, each a module of its own. The shell knows them by name only.
package enum ShellTool: String, CaseIterable, Identifiable, Sendable {
    case keepAwake, cleanScreen, lowLatency, batteryCare, focus
    package var id: String { rawValue }
    package var manifest: ModuleManifest {
        switch self {
        case .keepAwake: return BuiltinModuleManifests.keepAwake
        case .cleanScreen: return BuiltinModuleManifests.cleanScreen
        case .lowLatency: return BuiltinModuleManifests.lowLatency
        case .batteryCare: return BuiltinModuleManifests.batteryCare
        case .focus: return BuiltinModuleManifests.focus
        }
    }
    /// The tool's one declared entry: its inline settings row opens the tool's panel, and its
    /// render preview is that panel.
    package var options: NativeUIEntryRef { .init(manifest.id, "options") }
    package static func owning(_ module: String) -> ShellTool? { allCases.first { $0.manifest.id == module } }
}

/// What the shell may ask of the tools without seeing their models. Every answer already
/// accounts for the tool being switched off: no menu, nothing active, operations refused.
@MainActor package protocol ToolsApplicationAccess: AnyObject {
    func isActive(_ tool: ShellTool) -> Bool
    /// Rows for the tool's submenu in the status menu, or none while it is off.
    func menu(_ tool: ShellTool) -> [NativeMenuNode]
    /// The keep-awake marker beside the menu bar readings, empty when nothing is kept awake.
    var keepAwakeMarker: String { get }
    /// Called whenever the keep-awake state changes, so the menu bar title can follow.
    func observeKeepAwake(_ change: @escaping @MainActor () -> Void)
    /// `screen.*`, `awdl.*` and `keep-awake.*` app control operations.
    func handles(_ action: String) -> Bool
    func handle(_ request: AppControlRequest) async -> AppControlResponse
    /// Fields for the app control `status` reply.
    var statusValues: [String: String] { get }
    /// Returns true to cancel normal termination while a hardware change is being restored.
    func requestQuit() -> Bool
}
