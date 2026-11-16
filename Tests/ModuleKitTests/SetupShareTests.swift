import XCTest
@testable import ModuleKit

final class SetupShareTests: XCTestCase {
    func defaults() -> (UserDefaults, String) {
        let name = "thermo-setup-share-" + UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }

    func testExportCarriesOnlyAllowListedChoicesAndNoPersonalData() throws {
        let (d, name) = defaults(); defer { d.removePersistentDomain(forName: name) }
        d.set(true, forKey: "alertsEnabled"); d.set(true, forKey: "batteryChargeLimit80Enabled"); d.set(25, forKey: "focus.focusMinutes"); d.set("cpu", forKey: "titleMetric")
        d.set("/Users/someone/Pictures", forKey: "titleMetric.path")
        d.set(true, forKey: "localAI.consented"); d.set("secret", forKey: "bearer_token")
        d.set("/Users/someone/Desktop", forKey: "menuLayout")   // A path in an allow-listed key is still refused.
        d.set(false, forKey: ModulePreferences.key(BuiltinModuleManifests.capture.id))
        let doc = SetupShare.export(BuiltinModuleManifests.all, from: d)
        XCTAssertEqual(doc.settings["alertsEnabled"], .bool(true))
        XCTAssertEqual(doc.settings["focus.focusMinutes"], .int(25))
        XCTAssertEqual(doc.settings["titleMetric"], .string("cpu"))
        XCTAssertNil(doc.settings["menuLayout"]); XCTAssertNil(doc.settings["batteryChargeLimit80Enabled"]); XCTAssertNil(doc.settings["localAI.consented"]); XCTAssertNil(doc.settings["bearer_token"])
        XCTAssertEqual(doc.modules[BuiltinModuleManifests.capture.id], false)
        let text = String(decoding: try SetupShare.encode(doc), as: UTF8.self)
        XCTAssertFalse(text.contains("/Users")); XCTAssertFalse(text.contains("secret"))
    }

    func testReviewListsChangesAndSkipsUnknownOrUnsafeEntries() throws {
        let (source, a) = defaults(); defer { source.removePersistentDomain(forName: a) }
        let (target, b) = defaults(); defer { target.removePersistentDomain(forName: b) }
        let capture = BuiltinModuleManifests.capture.id, disk = BuiltinModuleManifests.disk.id
        source.set(true, forKey: ModulePreferences.key(capture)); source.set(false, forKey: ModulePreferences.key(disk))
        target.set(false, forKey: ModulePreferences.key(capture)); target.set(true, forKey: ModulePreferences.key(disk))
        source.set(50, forKey: "focus.focusMinutes")
        var doc = SetupShare.export(BuiltinModuleManifests.all, from: source)
        doc.modules["dev.example.unknown"] = true
        doc.settings["bearer_token"] = .string("x")
        doc.settings["titleMetric"] = .string("../../etc")
        let review = try SetupShare.review(try SetupShare.encode(doc), manifests: BuiltinModuleManifests.all, current: target)
        XCTAssertTrue(review.switchOn.contains(capture)); XCTAssertTrue(review.switchOff.contains(disk))
        XCTAssertEqual(review.settings["focus.focusMinutes"], .int(50))
        XCTAssertTrue(review.ignored.contains("dev.example.unknown")); XCTAssertTrue(review.ignored.contains("bearer_token")); XCTAssertTrue(review.ignored.contains("titleMetric"))
        SetupShare.applySettings(review, to: target)
        XCTAssertEqual(target.integer(forKey: "focus.focusMinutes"), 50); XCTAssertNil(target.object(forKey: "bearer_token"))
        XCTAssertFalse(target.bool(forKey: ModulePreferences.key(capture)), "switches are left to the feature center")
    }

    func testRejectsOtherFilesAndNewerVersions() throws {
        let (d, name) = defaults(); defer { d.removePersistentDomain(forName: name) }
        XCTAssertThrowsError(try SetupShare.review(Data("{}".utf8), manifests: [], current: d)) { XCTAssertEqual($0 as? SetupShare.ReadError, .notASetupFile) }
        var doc = SetupShare.Document(modules: [:], settings: [:]); doc.version = 99
        XCTAssertThrowsError(try SetupShare.review(try SetupShare.encode(doc), manifests: [], current: d)) { XCTAssertEqual($0 as? SetupShare.ReadError, .newerVersion(99)) }
    }
}
