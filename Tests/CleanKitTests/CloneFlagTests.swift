import XCTest
import Darwin
@testable import CleanKit

final class CloneFlagTests: XCTestCase {
    /// Skipping the private-size query for files that share no blocks must not hide a clone.
    func testClonesAreStillMeasuredByTheirPrivateBlocks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: dir + "/tree", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let original = dir + "/original.bin"
        FileManager.default.createFile(atPath: original, contents: Data(repeating: 7, count: 4 << 20))
        guard clonefile(original, dir + "/tree/clone.bin", 0) == 0 else { throw XCTSkip("not APFS") }
        FileManager.default.createFile(atPath: dir + "/tree/plain.bin", contents: Data(repeating: 9, count: 4 << 20))

        var flags: [String: Bool] = [:]
        BulkWalk.entries(of: dir + "/tree") { flags[$0.name] = $0.maySharesBlocks }
        XCTAssertEqual(flags["clone.bin"], true)
        XCTAssertEqual(flags["plain.bin"], false)

        let size = FS.size(dir + "/tree")
        XCTAssertGreaterThanOrEqual(size.allocated, 8 << 20)
        XCTAssertLessThan(size.bytes, size.allocated - (3 << 20), "the clone's shared 4 MB is not reclaimable")
        XCTAssertGreaterThanOrEqual(size.bytes, 4 << 20, "the plain file is")
    }
}
