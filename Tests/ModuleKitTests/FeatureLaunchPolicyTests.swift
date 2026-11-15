import Foundation
import XCTest
@testable import ModuleKit

final class FeatureLaunchPolicyTests: XCTestCase {
    private func fixture(_ body: (UserDefaults, String, URL) throws -> Void) rethrows {
        let domain = "thermo-first-run-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: home)
        }
        try body(defaults, domain, home)
    }

    func testFreshInstallHasExactlyTheFourCoreFeatures() {
        fixture { defaults, domain, home in
            let state = FeatureLaunchPolicy.assess(defaults: defaults, domain: domain, home: home)
            XCTAssertEqual(state.cohort, .fresh)
            XCTAssertTrue(state.needsSelection)
            FeatureLaunchPolicy.install(state, in: defaults, persist: true)
            XCTAssertEqual(Set(BuiltinModuleManifests.all.filter {
                ModulePreferences.isEnabled($0, in: defaults)
            }.map(\.id)), FeatureLaunchPolicy.coreIDs)
        }
    }

    func testRegisteredAndGlobalDefaultsAreNotUpgradeEvidence() {
        fixture { defaults, domain, home in
            defaults.register(defaults: ["interval": 2, "titleMetric": "cpu"])
            defaults.setVolatileDomain(["AppleLanguages": ["en"], "unrelatedGlobalPreference": true],
                                       forName: UserDefaults.globalDomain)
            XCTAssertNotNil(defaults.object(forKey: "interval"))
            XCTAssertEqual(FeatureLaunchPolicy.assess(defaults: defaults, domain: domain, home: home).cohort, .fresh)
            XCTAssertTrue(defaults.persistentDomain(forName: domain)?.isEmpty ?? true)
        }
    }

    func testDurablePreferencesPreserveLegacyAndEveryExplicitOff() {
        fixture { defaults, domain, home in
            for feature in BuiltinModuleManifests.all {
                defaults.set(false, forKey: ModulePreferences.key(feature.id))
            }
            let state = FeatureLaunchPolicy.assess(defaults: defaults, domain: domain, home: home)
            XCTAssertEqual(state.cohort, .legacy)
            XCTAssertFalse(state.needsSelection)
            FeatureLaunchPolicy.install(state, in: defaults, persist: true)
            for feature in BuiltinModuleManifests.all {
                XCTAssertFalse(ModulePreferences.isEnabled(feature, in: defaults), feature.id)
                defaults.removeObject(forKey: ModulePreferences.key(feature.id))
                XCTAssertTrue(ModulePreferences.isEnabled(feature, in: defaults), feature.id)
            }
        }
    }

    func testAppDataAlonePreservesAllFeaturesForLegacyUser() throws {
        try fixture { defaults, domain, home in
            let data = home.appendingPathComponent("Library/Application Support/Thermo")
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            try Data("old history".utf8).write(to: data.appendingPathComponent("pulse-history.jsonl"))
            let state = FeatureLaunchPolicy.assess(defaults: defaults, domain: domain, home: home)
            XCTAssertEqual(state.cohort, .legacy)
            XCTAssertFalse(state.needsSelection)
            FeatureLaunchPolicy.install(state, in: defaults, persist: true)
            XCTAssertTrue(BuiltinModuleManifests.all.allSatisfy { ModulePreferences.isEnabled($0, in: defaults) })
        }
    }

    func testInterruptedFirstLaunchRemainsPendingAfterStartupCreatesAppData() throws {
        try fixture { defaults, domain, home in
            let first = FeatureLaunchPolicy.assess(defaults: defaults, domain: domain, home: home)
            // The real app captures first before acquiring the lock, then persists only as the winner.
            try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Application Support/Thermo"),
                                                    withIntermediateDirectories: true)
            FeatureLaunchPolicy.install(first, in: defaults, persist: true)
            let restarted = FeatureLaunchPolicy.assess(defaults: defaults, domain: domain, home: home)
            XCTAssertEqual(restarted, first)
            FeatureLaunchPolicy.install(restarted, in: defaults, persist: true)
            XCTAssertTrue(restarted.needsSelection)
        }
    }

    func testSelectionPersistsAndSettingsCanStillChangeIt() {
        fixture { defaults, domain, home in
            FeatureLaunchPolicy.install(FeatureLaunchPolicy.assess(defaults: defaults, domain: domain, home: home), in: defaults, persist: true)
            let selected: Set<String> = [BuiltinModuleManifests.disk.id, BuiltinModuleManifests.search.id]
            FeatureLaunchPolicy.completeSelection(selected, in: defaults)
            XCTAssertFalse(FeatureLaunchPolicy.assess(defaults: defaults, domain: domain, home: home).needsSelection)
            for feature in BuiltinModuleManifests.all {
                XCTAssertEqual(ModulePreferences.isEnabled(feature, in: defaults), selected.contains(feature.id))
            }
            defaults.set(true, forKey: ModulePreferences.key(BuiltinModuleManifests.history.id))
            let next = FeatureLaunchPolicy.assess(defaults: defaults, domain: domain, home: home)
            FeatureLaunchPolicy.install(next, in: defaults, persist: true)
            XCTAssertTrue(ModulePreferences.isEnabled(BuiltinModuleManifests.history, in: defaults))
            XCTAssertFalse(ModulePreferences.isEnabled(BuiltinModuleManifests.performance, in: defaults))
        }
    }

    func testMissingBuiltinChoicesContinueToFollowCohortAndExternalModulesKeepManifestDefaults() {
        fixture { defaults, domain, home in
            FeatureLaunchPolicy.install(FeatureLaunchPolicy.assess(defaults: defaults, domain: domain, home: home), in: defaults, persist: true)
            // An absent choice is how a newly introduced builtin appears after an update.
            for feature in BuiltinModuleManifests.all {
                XCTAssertNil(defaults.persistentDomain(forName: domain)?[ModulePreferences.key(feature.id)])
                XCTAssertEqual(ModulePreferences.isEnabled(feature, in: defaults), FeatureLaunchPolicy.coreIDs.contains(feature.id))
            }
            let external = ModuleManifest(id: "com.example.optional", name: "External", summary: "", symbol: "folder", version: "1", enabledByDefault: true)
            XCTAssertTrue(ModulePreferences.isEnabled(external, in: defaults))
        }
    }

    func testReviewAndTestEntryPointsNeverConsumeSelection() {
        let modes = ["--disk", "--agents", "--chrome-pages", "--snapshot", "--offscreen", "--ui-review", "--render-preview", "--verify-lifecycle", "--dump-status-menu", "--show-status-menu", "--show-panel", "--install-helper", "--unknown-qa-mode"]
        for mode in modes {
            XCTAssertFalse(FeatureLaunchPolicy.allowsInteractiveSelection(arguments: ["Thermo", mode], environment: [:]), mode)
        }
        XCTAssertTrue(FeatureLaunchPolicy.allowsInteractiveSelection(arguments: ["Thermo"], environment: [:]))
        XCTAssertTrue(FeatureLaunchPolicy.allowsInteractiveSelection(arguments: ["Thermo", "--search"], environment: [:]))
        XCTAssertTrue(FeatureLaunchPolicy.allowsInteractiveSelection(arguments: ["Thermo", "--main"], environment: [:]))
        XCTAssertTrue(FeatureLaunchPolicy.allowsInteractiveSelection(arguments: ["Thermo", "--main", "--search"], environment: [:]))
        XCTAssertFalse(FeatureLaunchPolicy.allowsInteractiveSelection(arguments: ["Thermo"], environment: ["XCTestConfigurationFilePath": "isolated"]))
    }
    func testMainAndSearchWithAnyReviewParameterNeverConsumeSelection() {
        for launch in [["--main"], ["--search"], ["--main", "--search"]] {
            for parameter in ["--offscreen", "--snapshot", "--ui-review", "--page", "--render-preview", "--fixture", "--height", "--unknown", "review.json", "-SomeDefault"] {
                XCTAssertFalse(FeatureLaunchPolicy.allowsInteractiveSelection(arguments: ["Thermo"] + launch + [parameter], environment: [:]), "\(launch) \(parameter)")
            }
        }
        XCTAssertFalse(FeatureLaunchPolicy.allowsInteractiveSelection(arguments: ["Thermo", "test.xctest"], environment: [:]))
    }

    func testLegacyDataEvidenceIncludesSupportCachesAndLogsIndependently() throws {
        for path in ["Library/Application Support/Thermo", "Library/Application Support/dev.thermo",
                     "Library/Caches/Thermo", "Library/Caches/dev.thermo", "Library/Caches/dev.thermo.app",
                     "Library/Logs/Thermo", "Library/Logs/dev.thermo.app"] {
            try fixture { defaults, domain, home in
                try FileManager.default.createDirectory(at: home.appendingPathComponent(path), withIntermediateDirectories: true)
                let state = FeatureLaunchPolicy.assess(defaults: defaults, domain: domain, home: home)
                XCTAssertEqual(state.cohort, .legacy, path)
                XCTAssertFalse(state.needsSelection, path)
                FeatureLaunchPolicy.install(state, in: defaults, persist: true)
                XCTAssertTrue(BuiltinModuleManifests.all.allSatisfy { ModulePreferences.isEnabled($0, in: defaults) }, path)
            }
        }
    }

}
