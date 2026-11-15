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

    /// Call before startup creates app.lock, normalizes settings, or starts any feature.
    /// Only this app's durable domain counts; registration, argument and global domains do not.
    /// Existing app data is sufficient evidence of an upgrade, even with no custom preferences.
    public static func assess(defaults: UserDefaults, domain: String, home: URL) -> State {
        let saved = defaults.persistentDomain(forName: domain) ?? [:]
        if let raw = saved[cohortKey] as? String, let cohort = Cohort(rawValue: raw) {
            return State(cohort: cohort, needsSelection: cohort == .fresh && !(saved[selectionKey] as? Bool ?? false))
        }
        let data = home.appendingPathComponent("Library/Application Support/Thermo", isDirectory: true)
        let legacy = !saved.isEmpty || FileManager.default.fileExists(atPath: data.path)
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
        return coreIDs.contains(manifest.id)
    }

    /// Review, QA and test entry points must never consume the first launch or present a window.
    public static func allowsInteractiveSelection(arguments: [String], environment: [String: String]) -> Bool {
        guard environment["XCTestConfigurationFilePath"] == nil,
              environment["XCTestBundlePath"] == nil,
              environment["SWIFT_TESTING_ENABLED"] == nil else { return false }
        return !arguments.dropFirst().contains { $0.hasPrefix("--") && $0 != "--search" }
    }
}
