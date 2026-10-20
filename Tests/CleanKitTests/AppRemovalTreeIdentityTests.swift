import Darwin
import Foundation
@testable import CleanKit
import XCTest

final class AppRemovalTreeIdentityTests: XCTestCase {
    var directory: URL!
    var bundle: URL!
    var resource: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("app-removal-tree-" + UUID().uuidString)
        bundle = directory.appendingPathComponent("Fixture.app")
        resource = bundle.appendingPathComponent("Contents/Resources/Nested/asset")
        try FileManager.default.createDirectory(at: resource.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("before".utf8).write(to: resource)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testSameLengthWriteWithRestoredModificationTimeChangesReview() throws {
        let before = try XCTUnwrap(AppRemovalTreeIdentity.capture(bundle.path))
        var metadata = stat()
        XCTAssertEqual(lstat(resource.path, &metadata), 0)
        try Data("after!".utf8).write(to: resource)
        var times = [metadata.st_atimespec, metadata.st_mtimespec]
        XCTAssertEqual(utimensat(AT_FDCWD, resource.path, &times, 0), 0)
        var after = stat()
        XCTAssertEqual(lstat(resource.path, &after), 0)
        XCTAssertEqual(after.st_size, metadata.st_size)
        XCTAssertEqual(after.st_mtimespec.tv_sec, metadata.st_mtimespec.tv_sec)
        XCTAssertEqual(after.st_mtimespec.tv_nsec, metadata.st_mtimespec.tv_nsec)
        XCTAssertNotEqual(AppRemovalTreeIdentity.capture(bundle.path), before)
    }

    func testLinksDoNotIncludeExternalContentsButReplacementChangesReview() throws {
        let external = directory.appendingPathComponent("external")
        try Data("outside".utf8).write(to: external)
        let link = bundle.appendingPathComponent("Contents/link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        let before = try XCTUnwrap(AppRemovalTreeIdentity.capture(bundle.path))
        try Data("external changes are not files being removed".utf8).write(to: external)
        XCTAssertEqual(AppRemovalTreeIdentity.capture(bundle.path), before)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../Contents")
        XCTAssertNotEqual(AppRemovalTreeIdentity.capture(bundle.path), before)
        XCTAssertNotNil(AppRemovalTreeIdentity.capture(bundle.path), "A link cycle must not be followed")
    }

    func testIncompleteAndCancelledReviewCannotProduceIdentity() throws {
        XCTAssertNil(AppRemovalTreeIdentity.capture(bundle.path, maxEntries: 1))
        XCTAssertNil(AppRemovalTreeIdentity.capture(bundle.path, maxDepth: 0))
        XCTAssertNil(AppRemovalTreeIdentity.capture(bundle.path, timeout: 0))
        let token = ScanCancellation()
        token.cancel()
        XCTAssertNil(ScanCancellation.withCurrent(token) { AppRemovalTreeIdentity.capture(bundle.path) })
    }

    func testSpecialFileCannotBlockReviewOrBeMistakenForCompleteTree() throws {
        let pipe = bundle.appendingPathComponent("Contents/pipe").path
        XCTAssertEqual(mkfifo(pipe, 0o600), 0)
        XCTAssertNil(AppRemovalTreeIdentity.capture(bundle.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pipe))
    }
}
