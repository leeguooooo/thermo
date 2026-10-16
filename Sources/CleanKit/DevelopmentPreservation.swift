import Foundation

/// Regenerable data can still be expensive to lose during development. Keep it out of
/// automatic selections; an explicit item/category selection can still review it.
public extension CleanItem {
    var developmentDependency: Bool {
        if [.devCaches, .xcode, .projects, .aiModels, .agentWorktrees].contains(category) { return true }
        return ["playwright-browsers", "claude-desktop-vm", "mcp-caches"].contains(id)
    }

    var automaticallySelected: Bool {
        cleanable && safety == .safe && category != .aiSessions && !developmentDependency
    }
}

public enum DevelopmentPreservation {
    /// Archive defaults protect installed environments, not just a currently running app.
    public static func environment(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let roots = [home + "/Library/Developer", home + "/Library/Huawei", home + "/.android",
                     home + "/.Huawei", home + "/.rustup", home + "/.cargo", home + "/flutter_flutter",
                     "/Library/Developer", "/opt/homebrew"]
        return roots.contains { path == $0 || path.hasPrefix($0 + "/") }
            || path.contains("/dev.orbstack/") || path.contains(".dev.orbstack/")
    }
}
