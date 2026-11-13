import ModuleKit
import ThermoL10n

/// Thermo's own features that run inside the app. They are described by the same manifest as a
/// module that runs in its own process and are switched on and off in the same place; switched
/// off, a feature has no entry anywhere and none of its objects is created.
enum BuiltinModules {
    static let disk = ModuleManifest(
        id: "dev.thermo.disk", name: "Disk Cleanup", summary: "Finds caches, leftovers and old files that can go, and removes what you pick.",
        symbol: "sparkles", version: "1.0.0", launch: .onDemand, enabledByDefault: true,
        entries: [
            .init(id: "scan", kind: .page, title: "Smart Scan", symbol: "sparkles", scene: "disk"),
            .init(id: "overview", kind: .page, title: "Where the space is", symbol: "chart.pie", scene: "disk:overview"),
        ])

    static let all = [disk]

    static func manifest(_ id: String) -> ModuleManifest? { all.first { $0.id == id } }
}

extension MainPage {
    /// The module a page belongs to; nil for the pages that are Thermo itself.
    var module: String? {
        switch self {
        case .disk: return BuiltinModules.disk.id
        case let .module(id, _): return id
        default: return nil
        }
    }
}
