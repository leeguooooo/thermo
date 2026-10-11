import XCTest
import Darwin
@testable import CleanKit

final class DiskFootprintTests: XCTestCase {
    func testAllocationDiscoveryPreservesHardLinkAndSymlinkBoundaries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("one")
        try Data(repeating: 1, count: 1_048_576).write(to: file)
        try FileManager.default.linkItem(at: file, to: root.appendingPathComponent("two"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: URL(fileURLWithPath: "/Applications"))
        let footprint = FS.footprint(root.path)
        XCTAssertEqual(footprint.allocated, FS.size(root.path).allocated)
        XCTAssertLessThan(footprint.allocated, 2 * 1_048_576, "hard links count once and outside links are not traversed")
        XCTAssertLessThanOrEqual(footprint.files, 2)
        XCTAssertFalse(footprint.denied)
    }
    func testUsedSpaceAndReclaimableSpaceAreDifferentForExternallyLinkedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let tree = root.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = tree.appendingPathComponent("file")
        try Data(repeating: 1, count: 1_048_576).write(to: file)
        try FileManager.default.linkItem(at: file, to: root.appendingPathComponent("retained"))
        XCTAssertGreaterThan(FS.footprint(tree.path).allocated, 0)
        XCTAssertEqual(FS.size(tree.path).bytes, 0, "cleanup sizing still protects data linked outside the selected tree")
    }
    func testCancelledFootprintDoesNotStartAWalk() {
        let cancellation = ScanCancellation(); cancellation.cancel()
        let result = FS.footprint("/Applications", cancellation: cancellation)
        XCTAssertEqual(result.allocated, 0)
        XCTAssertEqual(result.files, 0)
    }
}
