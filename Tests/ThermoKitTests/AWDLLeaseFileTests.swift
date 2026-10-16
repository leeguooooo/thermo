import Darwin
import Foundation
import XCTest
@testable import ThermoKit

final class AWDLLeaseFileTests: XCTestCase {
    let value=AWDLRestoreRecord(index:15,wasUp:true,bootSession:"22222222-2222-2222-2222-222222222222")
    func fixture() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-awdl-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at:root) };return root
    }
    func testDurableRecordSurvivesReopenAndExclusiveCreationCannotOverwriteIt() throws {
        let root=try fixture()
        do { let file=AWDLLeaseFile(directory:root.path,owner:getuid());try file.save(value);XCTAssertEqual(try file.load(),value);XCTAssertThrowsError(try file.save(value)) }
        let reopened=AWDLLeaseFile(directory:root.path,owner:getuid());XCTAssertEqual(try reopened.load(),value)
        try reopened.clear(value);XCTAssertNil(try reopened.load());try reopened.clear(value)
    }
    func testLifetimeLockExcludesAnotherControllerAndReleasesOnDeinit() throws {
        let root=try fixture();var first: AWDLLeaseFile?=AWDLLeaseFile(directory:root.path,owner:getuid())
        XCTAssertNil(try first!.load())
        let second=AWDLLeaseFile(directory:root.path,owner:getuid());XCTAssertThrowsError(try second.load())
        first=nil;XCTAssertNil(try second.load())
    }
    func testUnsafeDirectoryAndWrongOwnerAreRejected() throws {
        let root=try fixture();let file=AWDLLeaseFile(directory:root.path,owner:getuid())
        XCTAssertEqual(chmod(root.path,0o777),0);XCTAssertThrowsError(try file.save(value))
        XCTAssertEqual(chmod(root.path,0o700),0)
        let wrong=AWDLLeaseFile(directory:root.path,owner:getuid() == 0 ? 501 : 0);XCTAssertThrowsError(try wrong.load())
    }
    func testSymlinkFIFOAndHardLinkedRecordsAreRejectedWithoutReadingThem() throws {
        let root=try fixture(),leaf=root.appendingPathComponent("dev.thermo.awdl-lease"),other=root.appendingPathComponent("other")
        let file=AWDLLeaseFile(directory:root.path,owner:getuid())
        try JSONEncoder().encode(value).write(to:other);chmod(other.path,0o600)
        try FileManager.default.createSymbolicLink(at:leaf,withDestinationURL:other);XCTAssertThrowsError(try file.load())
        try FileManager.default.removeItem(at:leaf);XCTAssertEqual(mkfifo(leaf.path,0o600),0);XCTAssertThrowsError(try file.load())
        try FileManager.default.removeItem(at:leaf);try FileManager.default.linkItem(at:other,to:leaf);XCTAssertThrowsError(try file.load())
        XCTAssertTrue(FileManager.default.fileExists(atPath:other.path))
    }
    func testCorruptOversizedOrLoosePermissionRecordIsNotAnAbsentLease() throws {
        let root=try fixture(),leaf=root.appendingPathComponent("dev.thermo.awdl-lease"),file=AWDLLeaseFile(directory:root.path,owner:getuid())
        for bytes in [Data(),Data("{}".utf8),Data(repeating:65,count:4096)] {
            try bytes.write(to:leaf);chmod(leaf.path,0o600);XCTAssertThrowsError(try file.load())
        }
        try JSONEncoder().encode(value).write(to:leaf);chmod(leaf.path,0o644);XCTAssertThrowsError(try file.load())
    }
    func testClearRefusesDifferentRecordAndPreservesBytes() throws {
        let root=try fixture(),file=AWDLLeaseFile(directory:root.path,owner:getuid());try file.save(value)
        let wrong=AWDLRestoreRecord(index:16,wasUp:true,bootSession:value.bootSession)
        XCTAssertThrowsError(try file.clear(wrong));XCTAssertEqual(try file.load(),value)
    }
    func testReplacedLockCannotKeepAuthorizingFileOperations() throws {
        let root=try fixture(),file=AWDLLeaseFile(directory:root.path,owner:getuid());XCTAssertNil(try file.load())
        let lock=root.appendingPathComponent("dev.thermo.awdl-lock");try FileManager.default.removeItem(at:lock)
        try Data().write(to:lock);chmod(lock.path,0o600)
        XCTAssertThrowsError(try file.save(value))
    }
    func testSameBytesInAReplacementFileAreNotTheOriginalRecoveryRecord() throws {
        let root=try fixture(),file=AWDLLeaseFile(directory:root.path,owner:getuid());try file.save(value)
        let leaf=root.appendingPathComponent("dev.thermo.awdl-lease"),data=try Data(contentsOf:leaf)
        try data.write(to:leaf,options:.atomic);chmod(leaf.path,0o600)
        XCTAssertThrowsError(try file.clear(value));XCTAssertEqual(try Data(contentsOf:leaf),data)
    }
}
