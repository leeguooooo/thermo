import XCTest
@testable import AgentCore
@testable import CleanKit

final class CleanupScaleTests: XCTestCase {
    /// An item with thousands of paths (one per agent session) is checked per path; that check
    /// must not redo the whole item's work each time (1,600 sessions took 8 minutes).
    func testThousandsOfPathsCleanInSeconds() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let dir = home + "/Library/Caches/fixture"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let paths = (0..<2000).map { dir + "/s\($0).jsonl" }
        for p in paths { FileManager.default.createFile(atPath: p, contents: Data("x".utf8)) }
        let item = CleanItem(id: "fixture", category: .aiCaches, title: "Fixture", safety: .safe, bytes: 2000, paths: paths)
        let processes = ProcessTable(entries: (0..<300).map { AgentProcess(pid: Int32(1000 + $0), name: "p\($0)", executable: "/usr/bin/p\($0)") })
        let start = Date()
        let result = Cleaner.clean(item, mode: .permanent, guard: Guard(home: home), processTable: processes)
        XCTAssertEqual(result.removed.count, 2000, "\(result.failed.prefix(3))")
        XCTAssertLessThan(Date().timeIntervalSince(start), 20)
    }
}
