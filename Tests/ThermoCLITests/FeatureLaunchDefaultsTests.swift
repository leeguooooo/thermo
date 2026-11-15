import Foundation
import ModuleKit
import XCTest
@testable import thermo

final class FeatureLaunchDefaultsTests: XCTestCase {
    func testCLIDefaultDiscoveryIsReadOnlyAndAgreesWithFreshApp() throws {
        let domain = "thermo-cli-first-run-" + UUID().uuidString
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: home) }
        let cli = try ModuleCLI.defaults(domain: domain, home: home.path)
        XCTAssertFalse(ModulePreferences.isEnabled(BuiltinModuleManifests.disk, in: cli))
        XCTAssertTrue(ModulePreferences.isEnabled(BuiltinModuleManifests.capture, in: cli))
        XCTAssertThrowsError(try ModuleCLI.requireEnabled(BuiltinModuleManifests.disk, defaults: cli))
        XCTAssertTrue(defaults.persistentDomain(forName: domain)?.isEmpty ?? true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
        XCTAssertTrue(FeatureLaunchPolicy.assess(defaults: defaults, domain: domain, home: home).needsSelection)
    }

    func testCLIReadsLegacyDataEvidenceWithoutMigratingOrDroppingFeatures() throws {
        let domain = "thermo-cli-upgrade-" + UUID().uuidString
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Application Support/Thermo"), withIntermediateDirectories: true)
        let cli = try ModuleCLI.defaults(domain: domain, home: home.path)
        XCTAssertTrue(BuiltinModuleManifests.all.allSatisfy { ModulePreferences.isEnabled($0, in: cli) })
        XCTAssertTrue(defaults.persistentDomain(forName: domain)?.isEmpty ?? true)
    }
}
