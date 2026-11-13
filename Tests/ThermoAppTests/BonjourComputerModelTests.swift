import Foundation
import XCTest
@testable import ThermoApp

final class BonjourComputerModelTests: XCTestCase {
    func txt(_ fields: [String]) -> Data {
        Data(fields.flatMap { [UInt8($0.utf8.count)] + Array($0.utf8) })
    }
    func device(_ name: String, _ suffix: String, kind: BluetoothDevice.Kind = .other, rssi: Int? = -40, connected: Bool = false) -> BluetoothDevice {
        .init(name: name, address: "00:00:00:00:00:" + suffix, connected: connected, kind: kind, levels: [], rssi: rssi)
    }

    func testReadsLengthPrefixedModelAndRejectsMalformedOrConflictingValues() {
        XCTAssertEqual(BonjourComputerModels.model(in: txt(["model=Mac17,2", "osxvers=26"])), "Mac17,2")
        XCTAssertEqual(BonjourComputerModels.model(in: txt(["MODEL=Mac16,1"])), "Mac16,1")
        XCTAssertEqual(BonjourComputerModels.model(in: Data([3, 120, 61, 255]) + txt(["model=Mac17,2"])), "Mac17,2")
        XCTAssertNil(BonjourComputerModels.model(in: Data([8, 1, 2])))
        XCTAssertNil(BonjourComputerModels.model(in: txt(["model=Mac17,2", "model=Mac16,1"])))
        XCTAssertNil(BonjourComputerModels.model(in: txt(["model="])))
        XCTAssertNil(BonjourComputerModels.model(in: txt(["other=Mac17,2"])))
    }

    func testComputerModelUsesIdentifierShapeRatherThanTheDeviceName() {
        for model in ["Mac17,2", "Mac16,1", "MacBookPro18,3", "Macmini9,1", "iMacPro1,1", "Xserve3,1"] {
            XCTAssertTrue(BonjourComputerModels.isMac(model), model)
        }
        for model in ["m5", "MacSamba", "Mac17,2/other", "Mac17,2\0", "iPhone15,2"] {
            XCTAssertFalse(BonjourComputerModels.isMac(model), model)
        }
    }

    func testShortNameHintIsExplicitAndDoesNotChangePairedIdentity() throws {
        let peers = (0..<8).map { device("headset\($0)", "0\($0)", kind: .headphones) }
        let original = BluetoothReport(powerOn: true, devices: peers + [device("m5", "09")])
        let result = original.withComputerModelHints(["m5": "Mac17,2"])
        let mac = try XCTUnwrap(result.devices.last)
        XCTAssertEqual(mac.name, "m5")
        XCTAssertEqual(mac.id, original.devices.last?.id)
        XCTAssertEqual(mac.kind, .computer)
        XCTAssertEqual(mac.computerModelHint, "Mac17,2")
        XCTAssertEqual(mac.symbol, "laptopcomputer")
        XCTAssertEqual(result.devices.count, original.devices.count)
        XCTAssertEqual(result.defaultDevices.first?.name, "m5")
        XCTAssertEqual(result.withComputerModelHints([:]), original, "a vanished hint must not turn into a confirmed computer")
    }

    func testAmbiguousNamesAndKnownTypesAreNeverReclassified() {
        let duplicates = BluetoothReport(powerOn: true, devices: [device("m5", "01"), device("M5", "02")])
        XCTAssertTrue(duplicates.computerModelCandidates.isEmpty)
        XCTAssertEqual(duplicates.withComputerModelHints(["m5": "Mac17,2"]), duplicates)
        let known = BluetoothReport(powerOn: true, devices: [device("m5", "01", kind: .keyboard), device("MacBook", "02", kind: .computer)])
        XCTAssertTrue(known.computerModelCandidates.isEmpty)
        XCTAssertEqual(known.withComputerModelHints(["m5": "Mac17,2", "macbook": "Mac16,1"]), known)
        XCTAssertEqual(device("AirPods", "03", kind: .computer).symbol, "laptopcomputer")
        XCTAssertEqual(device("AirPods", "04", kind: .keyboard).symbol, "keyboard")
        XCTAssertEqual(device("AirPods Pro", "05", kind: .speaker).symbol, "airpodspro")
    }

    func testPresenceIsPrioritizedButMissingBluetoothSignalDoesNotHideALANComputer() {
        let values = [device("missing", "01", rssi: nil), device("nearby", "02"), device("connected", "03", rssi: nil, connected: true)]
        XCTAssertEqual(BluetoothReport(powerOn: true, devices: values).computerModelCandidates, ["connected", "nearby", "missing"])
        let inferred = BluetoothReport(powerOn: true, devices: values).withComputerModelHints(["missing": "Mac17,2"])
        XCTAssertEqual(inferred.defaultDevices.first?.name, "connected")
        XCTAssertEqual(inferred.defaultDevices.first { !$0.connected }?.name, "missing")
        XCTAssertTrue(BluetoothReport(powerOn: false, devices: values).computerModelCandidates.isEmpty)
    }

    actor Calls {
        var names: [String] = []
        var active = 0
        var maximum = 0
        func begin(_ name: String) { names.append(name); active += 1; maximum = max(maximum, active) }
        func end() { active -= 1 }
    }

    func testLookupBoundsConcurrencyAndDeduplicatesNames() async {
        let calls = Calls()
        let names = (0..<40).map { "peer\($0)" }
        let result = await BonjourComputerModels.lookup(names + names) { name in
            await calls.begin(name)
            try? await Task.sleep(nanoseconds: 2_000_000)
            await calls.end()
            return .init(model: "Mac17,2")
        }
        let called = await calls.names, maximum = await calls.maximum
        XCTAssertEqual(called.count, BonjourComputerModels.limit)
        XCTAssertLessThanOrEqual(maximum, 4)
        XCTAssertEqual(result.models.count, BonjourComputerModels.limit)
    }

    func testDeniedAccessStopsFurtherQueriesAndPublishesNoPartialHints() async {
        let calls = Calls()
        let result = await BonjourComputerModels.lookup(["blocked"] + (0..<20).map { "peer\($0)" }) { name in
            await calls.begin(name)
            if name != "blocked" { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            await calls.end()
            return name == "blocked" ? .init(accessBlocked: true) : .init(model: "Mac17,2")
        }
        let called = await calls.names
        XCTAssertTrue(result.accessBlocked)
        XCTAssertTrue(result.models.isEmpty)
        XCTAssertLessThanOrEqual(called.count, 4)
    }

    func testCancelledLookupDoesNotPublishLateResults() async {
        let task = Task {
            await BonjourComputerModels.lookup(["peer"]) { _ in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                return .init(model: "Mac17,2")
            }
        }
        task.cancel()
        let result = await task.value
        XCTAssertTrue(result.models.isEmpty)
    }

    func testAppDeclaresLocalNetworkPurposeAndTheServiceItQueries() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("Resources/Info.plist")), format: nil) as? [String: Any]
        XCTAssertFalse((plist?["NSLocalNetworkUsageDescription"] as? String ?? "").isEmpty)
        XCTAssertTrue((plist?["NSBonjourServices"] as? [String] ?? []).contains("_device-info._tcp"))
    }
}

@MainActor final class ConnectionsModelHintLifecycleTests: XCTestCase {
    func testHidingThePageCancelsLookupAndRejectsItsLateAnswer() async {
        let entered = expectation(description: "lookup started")
        let cancelled = expectation(description: "lookup cancelled")
        let report = BluetoothReport(powerOn: true, devices: [.init(name: "peer", address: "00:00:00:00:00:01", connected: false, kind: .other, levels: [], rssi: -40)])
        let model = ConnectionsModel(bluetoothReader: { report }, computerModelResolver: { _ in
            entered.fulfill()
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { cancelled.fulfill() }
            // A misbehaving resolver can still deliver a result after cancellation.
            return .init(models: ["peer": "Mac17,2"])
        })
        XCTAssertFalse(model.samplingActive)
        XCTAssertNil(model.bluetooth)
        let owner = UUID()
        model.setVisible(true, owner: owner)
        await fulfillment(of: [entered], timeout: 3)
        model.setVisible(false, owner: owner)
        await fulfillment(of: [cancelled], timeout: 3)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while model.readingBluetooth && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(model.readingBluetooth)
        XCTAssertFalse(model.samplingActive)
        XCTAssertEqual(model.bluetooth?.devices.first?.kind, .other)
        XCTAssertNil(model.bluetooth?.devices.first?.computerModelHint)
    }
}
