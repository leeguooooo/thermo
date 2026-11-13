import Foundation

/// Pages still owned by the kernel. Migrating a page removes it here and declares its navigation
/// slot in the feature manifest instead. These are local App menu shortcuts, never global hotkeys.
public enum HostPageSpecification {
    public struct Page: Sendable {
        public let argument: String
        public let title: String
        public let key: String
        public init(_ argument: String, _ title: String, _ key: String = "") {
            self.argument = argument; self.title = title; self.key = key
        }
    }
    public static let pages: [Page] = [
        .init("overview", "Overview", "1"), .init("sensors", "Sensors", "2"), .init("fans", "Fans", "3"),
        .init("pages", "Browser pages", "4"), .init("agents", "AI Agent Diagnostics", "6"),
        .init("apps", "Software", "7"), .init("memory", "Memory usage", "8"),
        .init("cpu", "CPU usage", "9"), .init("gpu", "GPU usage", "0"),
        .init("space", "Space Lens"), .init("claude", "Claude tools"), .init("settings", "Settings", ",")
    ]
}

public enum ModuleNavigation {
    public struct Conflict: Sendable, Equatable {
        public let key: String
        public let module: String
        /// nil means the kernel owns this slot.
        public let owner: String?
    }
    /// Only active features claim shortcuts: turning one off releases its slot.
    public static func conflicts(_ active: [ModuleManifest]) -> [Conflict] {
        let core = Set(HostPageSpecification.pages.map(\.key).filter { !$0.isEmpty })
        var owners: [String: String] = [:], result: [Conflict] = []
        for manifest in active {
            for entry in manifest.entries where entry.kind == .page {
                guard let key = entry.navigationKey else { continue }
                if core.contains(key) { result.append(.init(key: key, module: manifest.id, owner: nil)) }
                else if let owner = owners[key] { result.append(.init(key: key, module: manifest.id, owner: owner)) }
                else { owners[key] = manifest.id }
            }
        }
        return result
    }
}
