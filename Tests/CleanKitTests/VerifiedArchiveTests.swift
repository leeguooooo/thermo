import XCTest
import Foundation
@testable import CleanKit

final class VerifiedArchiveTests: XCTestCase {
    var fixture: URL!
    var source: URL { fixture.appendingPathComponent("source ' $(touch unexpected)") }
    var target: URL { fixture.appendingPathComponent("NAS/archive ' image.tar") }
    var transport: VerifiedArchive.Transport {
        .init { command in ["/bin/sh", "-c", command.replacingOccurrences(of: "sha256sum ", with: "/usr/bin/shasum -a 256 ")] }
    }
    override func setUpWithError() throws {
        fixture = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".thermo-archive-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("synthetic archive bytes".utf8).write(to: source.appendingPathComponent("payload.txt"))
    }
    override func tearDownWithError() throws { if let fixture { try? FileManager.default.removeItem(at: fixture) } }

    func destination() throws -> SSHArchiveDestination { try .init("nas:" + target.path) }

    func testCopyIsDefaultAndVerifiedRemovalHasRecoveryReceipt() throws {
        let result = try VerifiedArchive.archive(source: source.path, destination: destination(), removeLocal: true,
                                                allowDevelopment: false, transport: transport, idle: { _ in })
        XCTAssertTrue(result.localRemoved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path + ".manifest.json"))
        XCTAssertEqual(result.sha256.count, 64)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.appendingPathComponent("unexpected").path), "Source/destination quotes must not become shell commands")
        XCTAssertNotNil(result.diskSpace.availableChangeBytes)
    }

    func testWrongRemoteChecksumNeverRemovesLocalFiles() throws {
        let failing = VerifiedArchive.Transport { command in
            let operation = command.hasPrefix("sha256sum") ? "printf '\(String(repeating: "0", count: 64))  wrong\\n'" : command
            return ["/bin/sh", "-c", operation]
        }
        XCTAssertThrowsError(try VerifiedArchive.archive(source: source.path, destination: destination(), removeLocal: true,
                                                         allowDevelopment: false, transport: failing, idle: { _ in }))
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("payload.txt")), "synthetic archive bytes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testDisconnectedWriterRetainsSourceInsteadOfCrashingOnBrokenPipe() throws {
        try Data(repeating: 42, count: 2 << 20).write(to: source.appendingPathComponent("large.bin"))
        let disconnected = VerifiedArchive.Transport { command in
            if command.contains("dd bs=1048576") { return ["/usr/bin/false"] }
            return ["/bin/sh", "-c", command]
        }
        XCTAssertThrowsError(try VerifiedArchive.archive(source: source.path, destination: destination(), removeLocal: true,
                                                         allowDevelopment: false, transport: disconnected, idle: { _ in }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("large.bin").path))
    }

    func testSourceChangesDuringTransferPreventRemoval() throws {
        let changing = VerifiedArchive.Transport { command in
            if command.hasPrefix("sha256sum") { try! Data("new work".utf8).write(to: self.source.appendingPathComponent("new-work.txt")) }
            return ["/bin/sh", "-c", command.replacingOccurrences(of: "sha256sum ", with: "/usr/bin/shasum -a 256 ")]
        }
        XCTAssertThrowsError(try VerifiedArchive.archive(source: source.path, destination: destination(), removeLocal: true,
                                                         allowDevelopment: false, transport: changing, idle: { _ in }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("payload.txt").path))
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("new-work.txt")), "new work")
    }

    func testSparseVirtualSizeDoesNotBecomeTransferSize() throws {
        let image = source.appendingPathComponent("sparse.img")
        FileManager.default.createFile(atPath: image.path, contents: nil)
        let f = try FileHandle(forWritingTo: image)
        try f.write(contentsOf: Data(repeating: 7, count: 4096))
        try f.seek(toOffset: 32 << 20); try f.write(contentsOf: Data(repeating: 9, count: 4096))
        try f.truncate(atOffset: 64 << 20); try f.close()
        let plan = try VerifiedArchive.plan(source: source.path, destination: destination())
        XCTAssertGreaterThanOrEqual(plan.logicalBytes, 64 << 20)
        XCTAssertLessThan(plan.payloadBytes, 1 << 20)
        let result = try VerifiedArchive.archive(source: source.path, destination: destination(), removeLocal: false,
                                                allowDevelopment: false, transport: transport, idle: { _ in })
        XCTAssertLessThan(result.archiveBytes, 1 << 20)
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))
        let restored = fixture.appendingPathComponent("restore")
        try FileManager.default.createDirectory(at: restored, withIntermediateDirectories: true)
        let unpack = Process(); unpack.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        unpack.arguments = ["-xSpf", target.path, "-C", restored.path]; try unpack.run(); unpack.waitUntilExit()
        XCTAssertEqual(unpack.terminationStatus, 0)
        let file = restored.appendingPathComponent(source.lastPathComponent).appendingPathComponent("sparse.img")
        XCTAssertEqual(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, 64 << 20)
        let readback = try FileHandle(forReadingFrom: file); defer { try? readback.close() }
        try readback.seek(toOffset: 32 << 20)
        XCTAssertEqual(readback.readData(ofLength: 4096), Data(repeating: 9, count: 4096))
    }

    func testHardLinksCanBeRemovedWithoutMistakingOurOwnCtimeChangeForNewWork() throws {
        try FileManager.default.linkItem(at: source.appendingPathComponent("payload.txt"), to: source.appendingPathComponent("hardlink.txt"))
        let result = try VerifiedArchive.archive(source: source.path, destination: destination(), removeLocal: true,
                                                allowDevelopment: false, transport: transport, idle: { _ in })
        XCTAssertTrue(result.localRemoved)
    }

    func testExistingArchiveCannotBeOverwritten() throws {
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep previous archive".utf8).write(to: target)
        XCTAssertThrowsError(try VerifiedArchive.archive(source: source.path, destination: destination(), removeLocal: true,
                                                         allowDevelopment: false, transport: transport, idle: { _ in }))
        XCTAssertEqual(try String(contentsOf: target), "keep previous archive")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testIdleCheckFailurePreventsAnyTransfer() throws {
        XCTAssertThrowsError(try VerifiedArchive.archive(source: source.path, destination: destination(), removeLocal: true,
                                                         allowDevelopment: false, transport: transport, idle: { _ in throw ArchiveFailure("fixture busy") }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testDestinationValidationRejectsSSHOptionsAndTraversal() {
        for spec in ["-oProxyCommand=evil:/archive/test.tar", "nas:relative.tar", "nas:/archive/../test.tar", "nas:/archive/test.tar\n"] {
            XCTAssertThrowsError(try SSHArchiveDestination(spec))
        }
    }
    func testStoppedPipeReadersFinishWithoutFoundationDescriptorExceptions() throws {
        for _ in 0..<40 {
            let running = try VerifiedArchive.Running(["/bin/sh", "-c", "printf ready; printf diagnostic >&2; /bin/sleep 0.05"])
            running.stop(); running.stop()
            XCTAssertEqual(running.drains.wait(timeout: .now() + 2), .success)
            XCTAssertNotEqual(try running.finish().status, 0)
        }
    }
    func testPrivateReadersDrainBothPipesCompletelyBeforeSuccess() throws {
        let running = try VerifiedArchive.Running(["/bin/sh", "-c", "/usr/bin/head -c 131072 /dev/zero; /usr/bin/head -c 65536 /dev/zero >&2"])
        try running.input.fileHandleForWriting.close()
        let result = try running.finish()
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output.count, 131072); XCTAssertEqual(result.error.count, 65536)
    }

}
