import Darwin
import Foundation
import XCTest
@testable import ThermoKit

final class ControlRecoveryDirectoryTests: XCTestCase {
    func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        chmod(root.path, 0o700)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testPrivateDirectoryCreationAndIdempotenceWithoutChangingParentMode() throws {
        let root = try fixture(); chmod(root.path, 0o755)
        try ControlRecoveryDirectory.prepare(parentPath: root.path, owner: getuid())
        try ControlRecoveryDirectory.prepare(parentPath: root.path, owner: getuid())
        for (url, mode) in [(root, 0o755), (root.appendingPathComponent("dev.thermo"), 0o700)] {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, mode)
        }
    }
    func testGroupWritableParentUnsafeChildAndSymlinkAreRefusedWithoutRepairingThem() throws {
        let root = try fixture(); chmod(root.path, 0o775)
        XCTAssertThrowsError(try ControlRecoveryDirectory.prepare(parentPath: root.path, owner: getuid()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("dev.thermo").path))
        chmod(root.path, 0o700)
        let child = root.appendingPathComponent("dev.thermo")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true); chmod(child.path, 0o777)
        XCTAssertThrowsError(try ControlRecoveryDirectory.prepare(parentPath: root.path, owner: getuid()))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: child.path)[.posixPermissions] as? NSNumber)?.intValue, 0o777)
        try FileManager.default.removeItem(at: child)
        let other = root.appendingPathComponent("other"); try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: child, withDestinationURL: other)
        XCTAssertThrowsError(try ControlRecoveryDirectory.prepare(parentPath: root.path, owner: getuid()))
    }
    func testSystemAWDLStoreUsesPrivateDirectoryAndKeepsLegacyEvidence() throws {
        let root = try fixture(), legacy = root.appendingPathComponent("legacy-awdl-lease")
        let io = AWDLLeaseFile.systemStore(parentPath: root.path, legacyRecord: legacy.path, owner: getuid())
        XCTAssertNil(try io.load())
        let record = AWDLRestoreRecord(index: 15, wasUp: true, bootSession: UUID().uuidString)
        try io.save(record)
        let bytes = Data("legacy evidence".utf8); try bytes.write(to: legacy)
        XCTAssertEqual(try io.load(), record, "a modern owned recovery record remains recoverable")
        try io.clear(record)
        XCTAssertEqual(try Data(contentsOf: legacy), bytes)
        XCTAssertThrowsError(try io.load())
        XCTAssertThrowsError(try io.save(record))
        try FileManager.default.removeItem(at: legacy)
        XCTAssertNil(try io.load())
        try io.save(record); XCTAssertEqual(try io.load(), record)
        try io.clear(record)
    }
}
