import Foundation

/// What a built-in feature leaves on the Mac besides its code: global shortcuts it registers while on,
/// and the files it keeps under the home folder. Switching the feature off releases the shortcuts at once;
/// the files are kept until the person moves them to the Trash from the stop report.
public struct ModuleFootprint: Sendable, Equatable {
    public struct Data: Sendable, Equatable {
        /// Relative to the home folder.
        public var path: String
        /// English string-table key; the app translates it.
        public var title: String
        public init(_ path: String, _ title: String) { self.path = path; self.title = title }
    }
    public var globalShortcuts: Bool
    public var loginItems: Bool
    public var data: [Data]
    public init(globalShortcuts: Bool = false, loginItems: Bool = false, data: [Data] = []) {
        self.globalShortcuts = globalShortcuts; self.loginItems = loginItems; self.data = data
    }
    public static let none = ModuleFootprint()
}

public enum BuiltinModuleFootprints {
    private static let support = "Library/Application Support/Thermo/"
    /// Only data a feature owns alone. Shared stores (operation history, cleanup batches, backups other
    /// features restore from) are never listed: trashing them would break another feature's undo.
    public static let table: [String: ModuleFootprint] = [
        BuiltinModuleManifests.capture.id: .init(globalShortcuts: true, data: [
            .init(support + "Pins", "Pinned screenshots"),
            .init(support + "CaptureDrafts", "Unsaved recordings"),
        ]),
        BuiltinModuleManifests.search.id: .init(globalShortcuts: true, data: [
            .init(support + "Search", "Search index"),
        ]),
        BuiltinModuleManifests.menuBar.id: .init(globalShortcuts: true),
        BuiltinModuleManifests.cleanScreen.id: .init(globalShortcuts: true),
        BuiltinModuleManifests.performance.id: .init(data: [
            .init(support + "pulse-history.jsonl", "Performance history"),
            .init(support + "memory-history.jsonl", "Memory history"),
            .init(support + "restart-tabs.json", "Tabs saved for restart"),
        ]),
        BuiltinModuleManifests.download.id: .init(data: [
            .init(support + "Downloads", "Unfinished downloads"),
        ]),
    ]
    public static func footprint(_ id: String) -> ModuleFootprint { table[id] ?? .none }
}
