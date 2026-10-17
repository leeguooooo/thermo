import XCTest
@testable import ThermoKit

final class BatteryChargingGateTests: XCTestCase {
    final class Fixture {
        let id = UUID().uuidString
        var currentID: String?
        var metadata: [FourCC: SMCKeyInfo] = [:]
        var values: [FourCC: [UInt8]] = [:]
        var saved: BatteryGateRecord?
        var writes: [(FourCC, [UInt8])] = []
        var failSave = false, failLoad = false, failClear = false, failRead = false
        var onSave: (() -> Void)?
        var onWrite: ((FourCC, [UInt8]) throws -> Bool)?
        init(_ layout: BatteryGateLayout = .legacyPair) {
            currentID = id
            for key in layout.keys {
                metadata[key] = .init(key: key, type: layout == .chte ? "ui32" : "hex_", size: UInt32(layout.enabled.count), attributes: 0xd4)
                values[key] = layout.enabled
            }
        }
        var io: BatteryGateIO { .init(info: { self.metadata[$0] }, read: { key in
            if self.failRead { throw BatteryGateError("read failed") }
            guard let info = self.metadata[key], let bytes = self.values[key] else { throw BatteryGateError("read failed") }
            return .init(key: key, type: info.type, bytes: bytes)
        }, write: { key, bytes in
            self.writes.append((key, bytes))
            XCTAssertNotNil(self.saved, "recovery must be durable before any write")
            if try self.onWrite?(key, bytes) ?? true { self.values[key] = bytes }
        }) }
        var store: BatteryGateStore { .init(load: {
            if self.failLoad { throw BatteryGateError("load failed") }; return self.saved
        }, save: { record in
            if self.failSave { throw BatteryGateError("save failed") }
            XCTAssertNil(self.saved); self.saved = record; self.onSave?()
        }, clear: { record in
            if self.failClear { throw BatteryGateError("clear failed") }
            XCTAssertEqual(self.saved, record); self.saved = nil
        }) }
        func controller() -> BatteryChargingGate { .init(io: io, store: store, hardwareID: { self.currentID }) }
    }

    func testLegacyHoldReadbackAndRestore() throws {
        let f = Fixture(), controller = f.controller()
        try controller.inhibit()
        XCTAssertEqual(f.writes.map(\.0), ["CH0B", "CH0C"])
        XCTAssertEqual(f.values["CH0B"], [2]); XCTAssertEqual(f.values["CH0C"], [2])
        XCTAssertEqual(controller.observation().gate, .inhibited)
        XCTAssertEqual(controller.observation().ownership, .owned)
        XCTAssertTrue(controller.recover()); XCTAssertNil(f.saved)
        XCTAssertEqual(f.values["CH0B"], [0]); XCTAssertEqual(f.values["CH0C"], [0])
    }

    func testCHTEUsesExactFourBytes() throws {
        let f = Fixture(.chte), controller = f.controller()
        try controller.inhibit()
        XCTAssertEqual(f.writes.map(\.0), ["CHTE"])
        XCTAssertEqual(f.values["CHTE"], [1, 0, 0, 0])
        XCTAssertTrue(controller.recover()); XCTAssertEqual(f.values["CHTE"], [0, 0, 0, 0])
    }

    func testExternalAndUnknownValuesCannotBeAcquired() {
        for bytes: [UInt8] in [[2], [1], [255], []] {
            let f = Fixture(); f.values["CH0B"] = bytes
            XCTAssertThrowsError(try f.controller().inhibit())
            XCTAssertTrue(f.writes.isEmpty); XCTAssertNil(f.saved)
        }
        let f = Fixture(); f.values["CH0B"] = [2]; f.values["CH0C"] = [2]
        XCTAssertEqual(f.controller().observation().ownership, .none)
        XCTAssertEqual(f.controller().observation().gate, .inhibited)
    }

    func testSaveOrLoadFailurePreventsEveryHardwareWrite() {
        for save in [true, false] {
            let f = Fixture(); f.failSave = save; f.failLoad = !save
            XCTAssertThrowsError(try f.controller().inhibit()); XCTAssertTrue(f.writes.isEmpty)
        }
    }

    func testSecondWriteMutatesThenThrowsAndBothKeysAreRecovered() {
        let f = Fixture(), controller = f.controller()
        f.onWrite = { key, bytes in
            if key == "CH0C", bytes == [2] {
                f.values[key] = bytes; throw BatteryGateError("transport failed after write")
            }
            return true
        }
        XCTAssertThrowsError(try controller.inhibit())
        XCTAssertEqual(f.values["CH0B"], [0]); XCTAssertEqual(f.values["CH0C"], [0]); XCTAssertNil(f.saved)
    }

    func testSuccessfulWriteWithoutMatchingReadbackIsFailure() {
        let f = Fixture(), controller = f.controller()
        f.onWrite = { _, bytes in bytes != [2] }
        XCTAssertThrowsError(try controller.inhibit()); XCTAssertNil(f.saved)
        XCTAssertEqual(f.values["CH0B"], [0]); XCTAssertEqual(f.writes.count, 1)
    }

    func testFailedRestorationRetainsRecordAndRestartRecoversIt() throws {
        let f = Fixture(), first = f.controller(); try first.inhibit()
        f.onWrite = { _, bytes in if bytes == [0] { throw BatteryGateError("restore denied") }; return true }
        XCTAssertFalse(first.recover()); XCTAssertNotNil(f.saved); XCTAssertNotNil(first.lastError)
        let restarted = f.controller()
        XCTAssertEqual(restarted.observation().ownership, .uncertain)
        f.onWrite = nil
        XCTAssertTrue(restarted.recover()); XCTAssertNil(f.saved)
        XCTAssertEqual(f.values["CH0B"], [0]); XCTAssertEqual(f.values["CH0C"], [0])
    }

    func testUnknownExternalValuePreventsAllRestorationWrites() throws {
        let f = Fixture(), controller = f.controller(); try controller.inhibit()
        f.values["CH0C"] = [1]; f.writes.removeAll()
        XCTAssertFalse(controller.recover()); XCTAssertNotNil(f.saved); XCTAssertTrue(f.writes.isEmpty)
        XCTAssertEqual(f.values["CH0B"], [2])
    }

    func testHardwareOrMetadataChangeKeepsRecoveryPending() throws {
        for changeID in [true, false] {
            let f = Fixture(), controller = f.controller(); try controller.inhibit(); f.writes.removeAll()
            if changeID { f.currentID = UUID().uuidString }
            else { f.metadata["CH0C"] = .init(key: "CH0C", type: "hex_", size: 1, attributes: 0) }
            XCTAssertFalse(controller.recover()); XCTAssertTrue(f.writes.isEmpty); XCTAssertNotNil(f.saved)
        }
    }

    func testClearFailureIsNotSuccessfulRecoveryAndCanRetry() throws {
        let f = Fixture(), controller = f.controller(); try controller.inhibit()
        f.failClear = true
        XCTAssertFalse(controller.recover()); XCTAssertNotNil(f.saved)
        let count = f.writes.count; f.failClear = false
        XCTAssertTrue(controller.recover()); XCTAssertEqual(count, f.writes.count); XCTAssertNil(f.saved)
    }

    func testChangeBetweenDurableSaveAndWriteIsNotOverwritten() {
        let f = Fixture(), controller = f.controller()
        f.onSave = { f.values["CH0C"] = [7] }
        XCTAssertThrowsError(try controller.inhibit())
        // Post-save preflight catches a changed later key before the first write.
        XCTAssertTrue(f.writes.isEmpty)
        XCTAssertEqual(f.values["CH0C"], [7]); XCTAssertNotNil(f.saved)
        XCTAssertFalse(controller.recover())
    }

    func testUnrecognizedMetadataAndRecoveryPayloadNeverAuthorizeWrites() {
        let f = Fixture(); f.metadata["CH0B"] = .init(key: "F0Md", type: "ui8 ", size: 1, attributes: 0xd4)
        XCTAssertThrowsError(try f.controller().inhibit()); XCTAssertTrue(f.writes.isEmpty)
        f.saved = .init(hardwareID: f.id, layout: .legacyPair, registers: Array(f.metadata.values))
        XCTAssertFalse(f.saved!.valid); XCTAssertFalse(f.controller().recover()); XCTAssertTrue(f.writes.isEmpty)
    }

    func testFailedAcquisitionCannotBecomeOwnedJustBecauseReadbackLaterWorks() {
        let f = Fixture(), controller = f.controller()
        f.onWrite = { key, bytes in
            f.values[key] = bytes
            if key == "CH0C", bytes == [2] { f.failRead = true }
            return false
        }
        XCTAssertThrowsError(try controller.inhibit()); XCTAssertNotNil(f.saved)
        f.failRead = false; f.onWrite = nil
        XCTAssertEqual(f.values["CH0B"], [2]); XCTAssertEqual(f.values["CH0C"], [2])
        XCTAssertEqual(controller.observation().ownership, .uncertain)
        XCTAssertTrue(controller.recover()); XCTAssertNil(f.saved)
    }

    func testLostReadbackDuringHoldRequiresRecoveryEvenAfterReadSucceeds() throws {
        let f = Fixture(), controller = f.controller(); try controller.inhibit()
        f.failRead = true
        XCTAssertEqual(controller.observation().ownership, .uncertain)
        f.failRead = false
        XCTAssertEqual(controller.observation().ownership, .uncertain)
        XCTAssertTrue(controller.recover())
    }

    func testReadOnlyObservationRecoveryClearsOldIssueWithoutClaimingControl() {
        let f = Fixture(), controller = f.controller(); f.failRead = true
        XCTAssertEqual(controller.observation().gate, .unknown); XCTAssertNotNil(controller.lastError)
        f.failRead = false
        XCTAssertEqual(controller.observation().gate, .allowed)
        XCTAssertEqual(controller.observation().ownership, .none)
        XCTAssertNil(controller.lastError); XCTAssertTrue(f.writes.isEmpty)
    }
}
