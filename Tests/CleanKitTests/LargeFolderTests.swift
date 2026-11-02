import Foundation
import XCTest
@testable import CleanKit

final class LargeFolderTests: XCTestCase {
    func testFindsDeepNonBuildFolderOutsideAnyRepositoryAndIgnoresBuildOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: root) }
        func file(_ path: String) throws {
            let full = root + "/" + path
            try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(count: 2_000_000).write(to: URL(fileURLWithPath: full))
        }
        try file("wechat/continuations/snapshot/data/a.bin")
        try file("wechat/continuations/snapshot/more/b.bin")
        try file("app/node_modules/x/c.bin")
        var options = ScanOptions(); options.home = root
        let ctx = ScanContext(options: options, now: Date(), processes: ProcessTable.current(.init(cpu: false)), agentDirs: [],
                              liveClaudeSessions: [], liveClaudeStarts: [])
        let found = Projects.largeFolders(roots: [root], ctx: ctx, threshold: 3_000_000)
        XCTAssertEqual(found.map { ($0.paths[0] as NSString).lastPathComponent }, ["snapshot"])
        XCTAssertEqual(found.first?.safety, .review)
        XCTAssertFalse(found.first?.automaticallySelected ?? true)
    }
}
