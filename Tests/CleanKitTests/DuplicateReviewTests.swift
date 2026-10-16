@testable import CleanKit
import Darwin
import Foundation
import XCTest

final class DuplicateReviewTests: XCTestCase {
    var root = ""
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: root + "/Downloads", withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(atPath: root) }
    func file(_ name: String) throws -> String {
        let path = root + "/Downloads/" + name
        try Data(repeating: 42, count: 4096).write(to: URL(fileURLWithPath: path))
        return path
    }
    func testComparisonCarriesIdentityAndOnlyObservedPrivateBytes() throws {
        let a = try file("a"), b = try file("b")
        let group = try XCTUnwrap(Duplicates.find(in: [root], minimum: 1).first)
        XCTAssertEqual(Set(group.paths), Set([a, b]))
        for path in group.paths { XCTAssertEqual(group.reviewIdentities?[path], ManualRemoval.reviewIdentity(path)) }
        XCTAssertEqual(group.reclaimable, group.paths.dropFirst().reduce(0) { $0 + (group.privateBytes?[$1] ?? 0) })
        XCTAssertEqual(group.privateBytes?[a], BulkWalk.fileSize(a)?.privateSize)
        XCTAssertEqual(group.privateBytes?[b], BulkWalk.fileSize(b)?.privateSize)
    }
    func testChangeBetweenShortAndFullComparisonCannotProduceAGroup() throws {
        _ = try file("a"); let b = try file("b")
        let groups = Duplicates.find(in: [root], minimum: 1) { _ in
            try? Data(repeating: 43, count: 4096).write(to: URL(fileURLWithPath: b))
        }
        XCTAssertTrue(groups.isEmpty)
    }
    func testHashRejectsReplacedPathSymlinkAndFIFOWithoutBlocking() throws {
        let a = try file("a"), identity = try XCTUnwrap(ManualRemoval.reviewIdentity(root + "/Downloads/a"))
        XCTAssertNotNil(Duplicates.fullHash(a, cancellation: ScanCancellation(), expected: identity))
        try FileManager.default.moveItem(atPath: a, toPath: a + "-original")
        _ = try file("a")
        XCTAssertNil(Duplicates.fullHash(a, cancellation: ScanCancellation(), expected: identity))
        let link = root + "/Downloads/link", fifo = root + "/Downloads/fifo"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: a)
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        XCTAssertNil(Duplicates.fullHash(link, cancellation: ScanCancellation()))
        XCTAssertNil(Duplicates.fullHash(fifo, cancellation: ScanCancellation()))
    }
    func testLegacyJSONDoesNotInventReviewProofOrPrivateSize() throws {
        let group = try JSONDecoder().decode(DuplicateGroup.self, from: Data(#"{"hash":"old","size":4096,"paths":["/a","/b"],"reclaimable":4096}"#.utf8))
        XCTAssertNil(group.reviewIdentities); XCTAssertNil(group.privateBytes); XCTAssertNil(group.reclaimableState)
    }
}
