import XCTest
@testable import CleanKit

final class SimulatorRemovalGuardTests: XCTestCase {
    func devices(_ state: String?, available: Bool = false) throws -> [String: [Simulators.Device]] {
        var device: [String: Any] = ["udid": "reviewed-device", "name": "Fixture", "isAvailable": available]
        if let state { device["state"] = state }
        let data = try JSONSerialization.data(withJSONObject: ["runtime": [device]])
        return try JSONDecoder().decode([String: [Simulators.Device]].self, from: data)
    }
    func testBootingBootedAndUnknownDevicesAreNeverRemoved() throws {
        for state in ["Booted", "Booting", nil] as [String?] {
            XCTAssertNotNil(Simulators.removalRefusal([["xcrun", "simctl", "delete", "reviewed-device"]],
                                                     runtimes: [], devices: try devices(state), requireUnavailable: true))
        }
        XCTAssertNil(Simulators.removalRefusal([["xcrun", "simctl", "delete", "reviewed-device"]],
                                              runtimes: [], devices: try devices("Shutdown"), requireUnavailable: true))
        XCTAssertNotNil(Simulators.removalRefusal([["xcrun", "simctl", "delete", "reviewed-device"]],
                                                 runtimes: [], devices: try devices("Shutdown", available: true), requireUnavailable: true))
    }
    func testOldBroadUnavailableCommandRequiresFreshScan() throws {
        XCTAssertNotNil(Simulators.removalRefusal([["xcrun", "simctl", "delete", "unavailable"]],
                                                 runtimes: [], devices: try devices("Shutdown"), requireUnavailable: true))
    }
    func testRuntimeRemovalProtectsAssociatedRunningDevice() throws {
        let runtime = try JSONDecoder().decode(Simulators.Runtime.self,
            from: Data(#"{"identifier":"runtime-image","runtimeIdentifier":"runtime","deletable":true,"state":"Ready"}"#.utf8))
        let command = [["xcrun", "simctl", "runtime", "delete", "runtime-image"]]
        XCTAssertNotNil(Simulators.removalRefusal(command, runtimes: [runtime], devices: try devices("Booted"), requireUnavailable: false))
        XCTAssertNil(Simulators.removalRefusal(command, runtimes: [runtime], devices: try devices("Shutdown"), requireUnavailable: false))
        XCTAssertNotNil(Simulators.removalRefusal(command, runtimes: [], devices: try devices("Shutdown"), requireUnavailable: false))
    }
    func testScanFreezesUnavailableDeviceIDs() throws {
        let inventory = try devices("Shutdown")
        var options = ScanOptions(); options.home = "/fixture"
        let ctx = ScanContext(options: options, now: Date(), processes: ProcessTable(entries: []), agentDirs: [], liveClaudeSessions: [])
        var device = try XCTUnwrap(inventory["runtime"]?.first)
        device.dataPathSize = 1_000_000
        let item = try XCTUnwrap(Simulators.items(runtimes: [], devices: ["runtime": [device]], ctx: ctx).first)
        XCTAssertEqual(item.commands, [["/usr/bin/xcrun", "simctl", "delete", "reviewed-device"]])
        XCTAssertFalse(item.commands?.contains { $0.contains("unavailable") } == true)
    }
}
