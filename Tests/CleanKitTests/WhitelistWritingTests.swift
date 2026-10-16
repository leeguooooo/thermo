@testable import CleanKit
import AgentCore
import Darwin
import Foundation
import XCTest

final class WhitelistWritingTests: XCTestCase {
    var home = ""
    var file: URL { Whitelist.url(home: home) }
    var folder: URL { file.deletingLastPathComponent() }
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(atPath: home) }
    func write(_ text: String, to path: URL? = nil) throws {
        let target = path ?? file; try Data(text.utf8).write(to: target)
        XCTAssertEqual(chmod(target.path, 0o600), 0)
    }
    func temporaryFiles(_ dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".whitelist.") && $0 != WhitelistWriteTransaction.lockName }
    }
    func testBusyWriterIsRefusedWithoutChangingProtection() throws {
        try write("~/old\n")
        let path = folder.appendingPathComponent(WhitelistWriteTransaction.lockName).path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600); XCTAssertGreaterThanOrEqual(fd, 0); defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0); defer { flock(fd, LOCK_UN) }
        XCTAssertThrowsError(try Whitelist.add(["~/new"], home: home))
        XCTAssertEqual(try Whitelist.loadForRemoval(home: home).entries, [home + "/old"])
    }
    func testNewExternalFileCannotBeOverwrittenByAnAbsentFileSnapshot() throws {
        XCTAssertThrowsError(try Whitelist.add(["~/new"], home: home, beforeCommit: { try self.write("~/external\n") }))
        XCTAssertEqual(try Whitelist.loadForRemoval(home: home).entries, [home + "/external"])
        XCTAssertTrue(try temporaryFiles(folder).isEmpty)
        XCTAssertTrue(OperationJournal.read(home: home).isEmpty)
    }
    func testInPlaceEditCannotBeOverwrittenByAStaleAdd() throws {
        try write("~/old\n"); let identity = FileIdentity.of(file.path)
        XCTAssertThrowsError(try Whitelist.add(["~/new"], home: home, beforeCommit: { try self.write("~/external\n") }))
        XCTAssertEqual(FileIdentity.of(file.path), identity)
        XCTAssertEqual(try Whitelist.loadForRemoval(home: home).entries, [home + "/external"])
        XCTAssertTrue(try temporaryFiles(folder).isEmpty)
    }
    func testExternalReplacementCannotBeOverwrittenByAStaleRemove() throws {
        try write("~/old\n~/keep\n")
        XCTAssertThrowsError(try Whitelist.remove(["~/old"], home: home, beforeCommit: {
            try Data("~/old\n~/keep\n~/external\n".utf8).write(to: self.file, options: .atomic)
        }))
        XCTAssertEqual(try Whitelist.loadForRemoval(home: home).entries, [home + "/old", home + "/keep", home + "/external"])
    }
    func testDirectoryReplacementKeepsBothConfigurationsAndCleansOnlyOwnedTemp() throws {
        try write("~/old\n")
        let old = folder.appendingPathExtension("moved")
        XCTAssertThrowsError(try Whitelist.add(["~/new"], home: home, beforeCommit: {
            try FileManager.default.moveItem(at: self.folder, to: old)
            try FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
            try self.write("~/external\n")
        }))
        XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("whitelist")), "~/old\n")
        XCTAssertEqual(try String(contentsOf: file), "~/external\n")
        XCTAssertTrue(try temporaryFiles(old).isEmpty)
    }
    func testReplacedTemporaryFileIsNeverCommittedOrDeletedAsOurFile() throws {
        try write("~/old\n")
        var foreign: URL?
        XCTAssertThrowsError(try Whitelist.add(["~/new"], home: home, beforeCommit: {
            let name = try XCTUnwrap(self.temporaryFiles(self.folder).first)
            let temp = self.folder.appendingPathComponent(name)
            try FileManager.default.moveItem(at: temp, to: self.folder.appendingPathComponent("saved-temp"))
            try self.write("~/foreign\n", to: temp); foreign = temp
        }))
        XCTAssertEqual(try String(contentsOf: file), "~/old\n")
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(foreign)), "~/foreign\n")
    }
    func testLockSpecialFilesAreRejectedWithoutTouchingTargets() throws {
        try write("~/old\n")
        let target = URL(fileURLWithPath: home + "/target"), path = folder.appendingPathComponent(WhitelistWriteTransaction.lockName)
        try write("untouched", to: target)
        for kind in ["symlink", "fifo", "hardlink"] {
            if kind == "symlink" { try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target) }
            else if kind == "hardlink" { try FileManager.default.linkItem(at: target, to: path) }
            else { XCTAssertEqual(mkfifo(path.path, 0o600), 0) }
            XCTAssertThrowsError(try Whitelist.add(["~/new"], home: home))
            XCTAssertEqual(try String(contentsOf: file), "~/old\n"); XCTAssertEqual(try String(contentsOf: target), "untouched")
            try FileManager.default.removeItem(at: path)
        }
    }
}
