import Foundation

/// A durable cohort, separate from individual feature choices. New builtins inherit this policy too.
public enum FeatureLaunchPolicy {
    public enum Cohort: String, Sendable { case fresh, legacy }
    public struct State: Equatable, Sendable {
        public let cohort: Cohort
        public let needsSelection: Bool
    }
    public static let cohortKey = "features.initialPolicy.v1"
    public static let selectionKey = "features.selectionCompleted.v1"
    public static let coreIDs: Set<String> = ["dev.thermo.capture", "dev.thermo.menu-bar", "dev.thermo.performance", "dev.thermo.search"]
    /// The menu bar tools were part of the app before they became modules, so they stay on for every
    /// cohort: a person who finished the first-launch choice before they existed has no saved choice
    /// for them, and switching them off by default would take away tools they had.
    public static let toolIDs: Set<String> = Set(BuiltinModuleManifests.tools.map(\.id))
    public static var defaultOnIDs: Set<String> { coreIDs.union(toolIDs) }

    /// Call before startup creates app.lock, normalizes settings, or starts any feature.
    /// Only this app's durable domain counts; registration, argument and global domains do not.
    /// Existing app data is sufficient evidence of an upgrade, even with no custom preferences.
    public static func assess(defaults: UserDefaults, domain: String, home: URL) -> State {
        let saved = defaults.persistentDomain(forName: domain) ?? [:]
        if let raw = saved[cohortKey] as? String, let cohort = Cohort(rawValue: raw) {
            return State(cohort: cohort, needsSelection: cohort == .fresh && !(saved[selectionKey] as? Bool ?? false))
        }
        let roots = ["Library/Application Support/Thermo", "Library/Application Support/dev.thermo",
                     "Library/Caches/Thermo", "Library/Caches/dev.thermo", "Library/Caches/dev.thermo.app",
                     "Library/Logs/Thermo", "Library/Logs/dev.thermo.app"]
        let legacy = !saved.isEmpty || roots.contains {
            FileManager.default.fileExists(atPath: home.appendingPathComponent($0).path)
        }
        return State(cohort: legacy ? .legacy : .fresh, needsSelection: !legacy)
    }

    /// The interactive app alone persists the cohort. CLI discovery registers it in memory only.
    public static func install(_ state: State, in defaults: UserDefaults, persist: Bool) {
        if persist { defaults.set(state.cohort.rawValue, forKey: cohortKey) }
        else { defaults.register(defaults: [cohortKey: state.cohort.rawValue]) }
    }

    public static func completeSelection(_ enabled: Set<String>, in defaults: UserDefaults) {
        for manifest in BuiltinModuleManifests.all {
            defaults.set(enabled.contains(manifest.id), forKey: ModulePreferences.key(manifest.id))
        }
        defaults.set(true, forKey: selectionKey)
    }

    public static func defaultEnabled(_ manifest: ModuleManifest, in defaults: UserDefaults) -> Bool {
        guard defaults.string(forKey: cohortKey) == Cohort.fresh.rawValue,
              BuiltinModuleManifests.all.contains(where: { $0.id == manifest.id }) else {
            return manifest.enabledByDefault
        }
        return defaultOnIDs.contains(manifest.id)
    }

    /// Review, QA and test entry points must never consume the first launch or present a window.
    public static func allowsInteractiveSelection(arguments: [String], environment: [String: String]) -> Bool {
        guard environment["XCTestConfigurationFilePath"] == nil,
              environment["XCTestBundlePath"] == nil,
              environment["SWIFT_TESTING_ENABLED"] == nil,
              !arguments.contains(where: { $0.contains(".xctest") }) else { return false }
        return arguments.dropFirst().allSatisfy { $0 == "--main" || $0 == "--search" }
    }
}
