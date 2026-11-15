import Foundation
import ModuleHost
import ModuleKit
import XCTest
@testable import ThermoShell
@testable import ThermoComposition

@MainActor final class FirstRunPrewarmTests: ThermoCompositionTestCase {
    func testPrewarmUsesCompletedSelectionAndSettingsCanEnableAnotherFeature() async {
        let domain = "thermo-first-run-prewarm-" + UUID().uuidString
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: home) }
        FeatureLaunchPolicy.install(FeatureLaunchPolicy.assess(defaults: defaults, domain: domain, home: home),
                                    in: defaults, persist: true)
        // A user enables Disk Cleanup and turns off Performance in the first launch selector.
        let selected: Set<String> = [BuiltinModuleManifests.disk.id, BuiltinModuleManifests.search.id]
        FeatureLaunchPolicy.completeSelection(selected, in: defaults)
        var started: [String] = []
        let center = ModuleCenter(manager: ModuleManager(app: home.appendingPathComponent("Thermo.app")),
                                  defaults: defaults, startBuiltin: { started.append($0) })
        center.start()
        XCTAssertEqual(Set(started), selected)
        XCTAssertFalse(center.isOn(BuiltinModuleManifests.performance.id))
        XCTAssertFalse(center.isOn(BuiltinModuleManifests.download.id))
        center.setEnabled(BuiltinModuleManifests.history.id, true)
        XCTAssertTrue(center.isOn(BuiltinModuleManifests.history.id))
        XCTAssertEqual(started.last, BuiltinModuleManifests.history.id)
        // Drain the empty-bundle discovery task without starting any real module or reader.
        for _ in 0..<100 where !center.loaded { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(center.loaded)
    }
}
