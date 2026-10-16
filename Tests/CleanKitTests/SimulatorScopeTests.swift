@testable import CleanKit
import AgentCore
import Foundation
import XCTest

final class SimulatorScopeTests: XCTestCase {
    let home = "/fixture"
    var asset: String { home + "/com_apple_MobileAsset_iOSSimulatorRuntime/one.asset" }
    func runtime() -> [String: Any] {
        ["identifier": "IMAGE", "runtimeIdentifier": "runtime", "deletable": true, "state": "Ready", "sizeBytes": 8000000000,
         "path": asset + "/AssetData/Restore/image.dmg", "runtimeBundlePath": home + "/Volumes/IMAGE/Runtime.simruntime",
         "mountPath": home + "/Volumes/IMAGE", "parentMountPath": asset + "/AssetData"]
    }
    func device(_ id: String = "A", state: String = "Shutdown", available: Bool = true) -> [String: Any] {
        ["udid": id, "name": "fixture", "state": state, "isAvailable": available, "dataPath": home + "/Devices/" + id + "/data",
         "logPath": home + "/Logs/" + id, "dataPathSize": 600000000, "lastUsedAt": "2020-01-01T00:00:00Z"]
    }
    func item(devices entries: [[String: Any]]? = nil) throws -> CleanItem {
        let runtimes = try JSONDecoder().decode([Simulators.Runtime].self, from: JSONSerialization.data(withJSONObject: [runtime()]))
        let devices = try JSONDecoder().decode([String: [Simulators.Device]].self, from: JSONSerialization.data(withJSONObject: ["runtime": entries ?? [device()]]))
        var options = ScanOptions(); options.home = home
        let context = ScanContext(options: options, now: Date(), processes: .init(entries: []), agentDirs: [], liveClaudeSessions: [])
        return try XCTUnwrap(Simulators.items(runtimes: runtimes, devices: devices, ctx: context).first { $0.id == "simulator-runtime/IMAGE" })
    }
    func reader(runtime image: [String: Any]? = nil, devices entries: [[String: Any]]? = nil, includeRuntime: Bool = true) -> ManagedToolScope.Runner {
        { command in
            let object: [String: Any]
            if Array(command.suffix(4)) == ["simctl", "list", "devices", "-j"] {
                object = ["devices": ["runtime": entries ?? [self.device()]]]
            } else if Array(command.suffix(4)) == ["simctl", "runtime", "list", "-j"] {
                XCTAssertTrue(includeRuntime, "device follow-up must not query a deleted runtime")
                object = includeRuntime ? ["IMAGE": image ?? self.runtime()] : [:]
            } else { XCTFail("Only metadata queries are permitted"); return (1, "unexpected command") }
            guard let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) else { return (1, "fixture encode error") }
            return (0, text)
        }
    }
    func testReviewIncludesAssetMetadataDeviceDirectoryAndLogsWithoutDeletionPaths() throws {
        let plan = try item()
        XCTAssertTrue(plan.paths.isEmpty); XCTAssertEqual(plan.commandScopes?.count, 2)
        for path in [asset, home + "/Devices/A", home + "/Logs/A"] { XCTAssertTrue(plan.commandScope?.contains(path) == true) }
        XCTAssertNil(Simulators.reviewRefusal(plan))
    }
    func testDeviceAndAssetProtectionBlocksRuntimeWhileUnrelatedProtectionAllowsIt() throws {
        let plan = try item(), command = try XCTUnwrap(plan.commands?.first)
        for protected in [asset + "/Info.plist", home + "/Devices/A/data/keep", home + "/Logs/A/keep"] {
            XCTAssertNotNil(Simulators.currentScopeRefusal(command, item: plan, whitelist: .init(file: "/fixture", entries: [protected]), home: home, run: reader()))
        }
        XCTAssertNil(Simulators.currentScopeRefusal(command, item: plan, whitelist: .init(file: "/fixture", entries: [home + "/unrelated"]), home: home, run: reader()))
    }
    func testNewAssociatedDeviceAndChangedImagePathRequireFreshReview() throws {
        let plan = try item(), command = try XCTUnwrap(plan.commands?.first)
        XCTAssertNotNil(Simulators.currentScopeRefusal(command, item: plan, whitelist: .init(file: "/fixture"), home: home, run: reader(devices: [device(), device("B")])))
        var image = runtime(); image["path"] = home + "/other-image.dmg"
        XCTAssertNotNil(Simulators.currentScopeRefusal(command, item: plan, whitelist: .init(file: "/fixture"), home: home, run: reader(runtime: image)))
    }
    func testDeviceCleanupFollowsRuntimeRemovalWithoutRequiringTheMissingRuntime() throws {
        let plan = try item(), command = try XCTUnwrap(plan.commands?.last)
        XCTAssertNil(Simulators.currentScopeRefusal(command, item: plan, whitelist: .init(file: "/fixture"), home: home, run: reader(devices: [device(available: false)], includeRuntime: false)))
    }
    func testNewUseRunningDevicesAndUnknownDeletionPermissionAreRefused() throws {
        let plan = try item(), command = try XCTUnwrap(plan.commands?.first)
        var changed = device(); changed["lastUsedAt"] = "2026-10-16T00:00:00Z"
        XCTAssertNotNil(Simulators.currentScopeRefusal(command, item: plan, whitelist: .init(file: "/fixture"), home: home, run: reader(devices: [changed])))
        for state in ["Booted", "Booting"] {
            XCTAssertNotNil(Simulators.currentScopeRefusal(command, item: plan, whitelist: .init(file: "/fixture"), home: home, run: reader(devices: [device(state: state)])))
        }
        var image = runtime(); image.removeValue(forKey: "deletable")
        XCTAssertNotNil(Simulators.currentScopeRefusal(command, item: plan, whitelist: .init(file: "/fixture"), home: home, run: reader(runtime: image)))
    }
    func testSelectorsAbsoluteExecutablesAndLegacyItemsCannotBypassReview() throws {
        XCTAssertNil(Simulators.target(["xcrun", "simctl", "delete", "all"]))
        XCTAssertNil(Simulators.target(["/usr/bin/xcrun", "simctl", "runtime", "delete", "all"]))
        XCTAssertNil(Simulators.target(["/untrusted/xcrun", "simctl", "delete", "A"]))
        XCTAssertTrue(Simulators.isCommand(["/usr/bin/xcrun", "simctl", "delete", "A"]))
        let legacy = CleanItem(id: "simulator-unavailable", category: .xcode, title: "fixture", safety: .safe, bytes: 1, commands: [["xcrun", "simctl", "delete", "A"]])
        XCTAssertNotNil(Simulators.reviewRefusal(legacy)); XCTAssertFalse(Whitelist(file: "/fixture").apply(legacy).cleanable)
        var missing = try item(); missing.commandScopes = []
        XCTAssertNotNil(Simulators.reviewRefusal(missing))
    }
    func testMissingLocationsBlockCandidateAndFractionalUseDatesAreSupported() throws {
        var incomplete = device(); incomplete.removeValue(forKey: "logPath")
        XCTAssertNotNil(try item(devices: [incomplete]).blocked)
        XCTAssertNotNil(Simulators.date("2026-10-16T00:00:00.125Z"))
    }
}
