@testable import CleanKit
import ThermoL10n
import XCTest

final class SimulatorAppDataTests: XCTestCase {
    var home = ""
    let now = Date()

    override func setUpWithError() throws {
        L10n.override = .english
        home = FileManager.default.temporaryDirectory.appendingPathComponent("sim-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: home) }

    func context() -> ScanContext {
        var o = ScanOptions()
        o.home = home
        o.olderThanDays = 30
        return ScanContext(options: o, now: now, processes: ProcessTable(entries: []), agentDirs: [], liveClaudeSessions: [])
    }

    func iso(_ daysAgo: Double) -> String { Simulators.iso.string(from: now.addingTimeInterval(-daysAgo * 86400)) }

    func testRuntimesAndDevices() {
        var runtimes = [
            Simulators.Runtime(identifier: "OLD", version: "27.2", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-2",
                               sizeBytes: 8_000_000_000, lastUsedAt: nil, deletable: true),
            Simulators.Runtime(identifier: "USED", version: "26.5", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
                               sizeBytes: 8_500_000_000, lastUsedAt: iso(2), deletable: true),
            Simulators.Runtime(identifier: "SYS", version: "18.0", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-0",
                               sizeBytes: 7_000_000_000, lastUsedAt: nil, deletable: false),
        ]
        var devices: [String: [Simulators.Device]] = [
            "com.apple.CoreSimulator.SimRuntime.iOS-27-2": [
                .init(udid: "A", name: "iPhone 18", state: "Shutdown", isAvailable: true, dataPath: nil, dataPathSize: 10_000_000, lastBootedAt: nil),
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
                .init(udid: "B", name: "iPad Air", state: "Shutdown", isAvailable: true, dataPath: nil, dataPathSize: 3_400_000_000, lastBootedAt: iso(90)),
                .init(udid: "C", name: "iPhone 17", state: "Booted", isAvailable: true, dataPath: nil, dataPathSize: 2_000_000_000, lastBootedAt: iso(60)),
                .init(udid: "D", name: "Gone", state: "Shutdown", isAvailable: false, dataPath: nil, dataPathSize: 600_000_000, lastBootedAt: nil),
            ],
        ]
        for index in runtimes.indices {
            let id = runtimes[index].identifier
            runtimes[index].path = home + "/Images/" + id + ".dmg"
            runtimes[index].mountPath = home + "/Volumes/" + id
            runtimes[index].parentMountPath = home + "/Parents/" + id
            runtimes[index].runtimeBundlePath = home + "/Volumes/" + id + "/Runtime.simruntime"
            runtimes[index].state = "Ready"
        }
        for (runtime, entries) in devices {
            devices[runtime] = entries.map { original in
                var device = original
                device.dataPath = home + "/Devices/" + device.udid + "/data"
                device.logPath = home + "/Logs/" + device.udid
                return device
            }
        }
        let items = Simulators.items(runtimes: runtimes, devices: devices, ctx: context())
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

        let old = try? XCTUnwrap(byID["simulator-runtime/OLD"])
        XCTAssertEqual(old?.title, "Simulator runtime · iOS 27.2")
        XCTAssertEqual(old?.commands, [["/usr/bin/xcrun", "simctl", "runtime", "delete", "OLD"], ["/usr/bin/xcrun", "simctl", "delete", "A"]])
        XCTAssertTrue(old?.cleanable ?? false, "commands alone make an item cleanable")
        XCTAssertNil(byID["simulator-runtime/USED"], "used two days ago")
        XCTAssertNil(byID["simulator-runtime/SYS"], "not deletable")

        XCTAssertEqual(byID["simulator-unavailable"]?.commands, [["/usr/bin/xcrun", "simctl", "delete", "D"]])
        XCTAssertEqual(byID["simulator-device/B"]?.commands, [["/usr/bin/xcrun", "simctl", "erase", "B"]])
        XCTAssertNotNil(byID["simulator-device/C"]?.blocked, "a running simulator is not erased")
        XCTAssertNil(byID["simulator-device/A"], "small device data is not worth a line")
    }

    func testCleanerRunsCommandsAndReportsFailure() {
        let ok = CleanItem(id: "ok", category: .xcode, title: "ok", safety: .safe, bytes: 42, commands: [["true"]])
        let r = Cleaner.clean(ok, guard: Guard(home: home))
        XCTAssertEqual(r.bytes, 42)
        XCTAssertEqual(r.removed, ["ran: true"])

        let bad = CleanItem(id: "bad", category: .xcode, title: "bad", safety: .safe, bytes: 42, commands: [["false"]])
        let f = Cleaner.clean(bad, guard: Guard(home: home))
        XCTAssertEqual(f.bytes, 0, "nothing freed when a command fails")
        XCTAssertEqual(f.failed.keys.sorted(), ["false"])
    }

    func testChatAppsAreInformationOnly() throws {
        let dir = home + "/Library/Group Containers/group.net.whatsapp.WhatsApp.shared"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        XCTAssertTrue(AppData.scan(context()).isEmpty, "below 1 GB nothing is shown")
        XCTAssertTrue(AppData.apps.allSatisfy { !$0.howTo.isEmpty })
    }
}
