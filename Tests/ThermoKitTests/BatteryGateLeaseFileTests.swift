import Darwin
import Foundation
import XCTest
@testable import ThermoKit

final class BatteryGateLeaseFileTests: XCTestCase {
    let value=BatteryGateRecord(hardwareID:"22222222-2222-2222-2222-222222222222",layout:.chte,registers:[.init(key:"CHTE",type:"ui32",size:4,attributes:0xd4)])
    func fixture() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-charge-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at:root) };return root
    }
    func testDurableRecordSurvivesReopenAndExclusiveCreationCannotOverwriteIt() throws {
        let root=try fixture()
        do { let file=BatteryGateLeaseFile(directory:root.path,owner:getuid());try file.save(value);XCTAssertEqual(try file.load(),value);XCTAssertThrowsError(try file.save(value)) }
        let reopened=BatteryGateLeaseFile(directory:root.path,owner:getuid());XCTAssertEqual(try reopened.load(),value)
        try reopened.clear(value);XCTAssertNil(try reopened.load());try reopened.clear(value)
    }
    func testLifetimeLockExcludesAnotherControllerAndReleasesOnDeinit() throws {
        let root=try fixture();var first: BatteryGateLeaseFile?=BatteryGateLeaseFile(directory:root.path,owner:getuid())
        XCTAssertNil(try first!.load())
        let second=BatteryGateLeaseFile(directory:root.path,owner:getuid());XCTAssertThrowsError(try second.load())
        first=nil;XCTAssertNil(try second.load())
    }
    func testUnsafeDirectoryAndWrongOwnerAreRejected() throws {
        let root=try fixture();let file=BatteryGateLeaseFile(directory:root.path,owner:getuid())
        XCTAssertEqual(chmod(root.path,0o777),0);XCTAssertThrowsError(try file.save(value))
        XCTAssertEqual(chmod(root.path,0o700),0)
        let wrong=BatteryGateLeaseFile(directory:root.path,owner:getuid() == 0 ? 501 : 0);XCTAssertThrowsError(try wrong.load())
    }
    func testSymlinkFIFOAndHardLinkedRecordsAreRejectedWithoutReadingThem() throws {
        let root=try fixture(),leaf=root.appendingPathComponent("dev.thermo.charge-lease"),other=root.appendingPathComponent("other")
        let file=BatteryGateLeaseFile(directory:root.path,owner:getuid())
        try JSONEncoder().encode(value).write(to:other);chmod(other.path,0o600)
        try FileManager.default.createSymbolicLink(at:leaf,withDestinationURL:other);XCTAssertThrowsError(try file.load())
        try FileManager.default.removeItem(at:leaf);XCTAssertEqual(mkfifo(leaf.path,0o600),0);XCTAssertThrowsError(try file.load())
        try FileManager.default.removeItem(at:leaf);try FileManager.default.linkItem(at:other,to:leaf);XCTAssertThrowsError(try file.load())
        XCTAssertTrue(FileManager.default.fileExists(atPath:other.path))
    }
    func testCorruptOversizedOrLoosePermissionRecordIsNotAnAbsentLease() throws {
        let root=try fixture(),leaf=root.appendingPathComponent("dev.thermo.charge-lease"),file=BatteryGateLeaseFile(directory:root.path,owner:getuid())
        for bytes in [Data(),Data("{}".utf8),Data(repeating:65,count:4096)] {
            try bytes.write(to:leaf);chmod(leaf.path,0o600);XCTAssertThrowsError(try file.load())
        }
        try JSONEncoder().encode(value).write(to:leaf);chmod(leaf.path,0o644);XCTAssertThrowsError(try file.load())
    }
    func testClearRefusesDifferentRecordAndPreservesBytes() throws {
        let root=try fixture(),file=BatteryGateLeaseFile(directory:root.path,owner:getuid());try file.save(value)
        let wrong=BatteryGateRecord(hardwareID:"33333333-3333-3333-3333-333333333333",layout:.chte,registers:value.registers)
        XCTAssertThrowsError(try file.clear(wrong));XCTAssertEqual(try file.load(),value)
    }
    func testReplacedLockCannotKeepAuthorizingFileOperations() throws {
        let root=try fixture(),file=BatteryGateLeaseFile(directory:root.path,owner:getuid());XCTAssertNil(try file.load())
        let lock=root.appendingPathComponent("dev.thermo.charge-lock");try FileManager.default.removeItem(at:lock)
        try Data().write(to:lock);chmod(lock.path,0o600)
        XCTAssertThrowsError(try file.save(value))
    }
    func testSameBytesInAReplacementFileAreNotTheOriginalRecoveryRecord() throws {
        let root=try fixture(),file=BatteryGateLeaseFile(directory:root.path,owner:getuid());try file.save(value)
        let leaf=root.appendingPathComponent("dev.thermo.charge-lease"),data=try Data(contentsOf:leaf)
        try data.write(to:leaf,options:.atomic);chmod(leaf.path,0o600)
        XCTAssertThrowsError(try file.clear(value));XCTAssertEqual(try Data(contentsOf:leaf),data)
    }

    func testControllerReconstructionRestoresDurableCHTELease() throws {
        let root = try fixture(), f = BatteryChargingGateTests.Fixture(.chte)
        do {
            let file = BatteryGateLeaseFile(directory: root.path, owner: getuid())
            let disk = file.io
            let store = BatteryGateStore(load: disk.load, save: {
                try disk.save($0); f.saved = $0
            }, clear: { try disk.clear($0); f.saved = nil })
            let controller = BatteryChargingGate(io: f.io, store: store, hardwareID: { f.id })
            try controller.inhibit()
            XCTAssertEqual(try file.load()?.layout, .chte)
            XCTAssertEqual(f.values["CHTE"], [1, 0, 0, 0])
        }
        let reopened = BatteryGateLeaseFile(directory: root.path, owner: getuid())
        let reconstructed = BatteryChargingGate(io: f.io, store: reopened.io, hardwareID: { f.id })
        XCTAssertEqual(reconstructed.observation().ownership, .uncertain)
        XCTAssertTrue(reconstructed.recover())
        XCTAssertEqual(f.values["CHTE"], [0, 0, 0, 0])
        XCTAssertNil(try reopened.load())
    }
}
