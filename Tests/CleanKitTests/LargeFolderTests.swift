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
        XCTAssertFalse(found.first?.bulkSelectable ?? true)
    }

    func testHiddenToolFoldersInHomeAreNeverOfferedAsLargeFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: root) }
        for path in [".codex/artifacts/a.bin", ".codex/artifacts/b.bin", ".claude/projects/a.bin", ".claude/projects/b.bin"] {
            let full = root + "/" + path
            try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(count: 2_000_000).write(to: URL(fileURLWithPath: full))
        }
        var options = ScanOptions(); options.home = root
        let ctx = ScanContext(options: options, now: Date(), processes: ProcessTable.current(.init(cpu: false)), agentDirs: [],
                              liveClaudeSessions: [], liveClaudeStarts: [])
        XCTAssertEqual(Projects.largeFolders(roots: [root + "/.codex", root + "/.claude"], ctx: ctx, threshold: 3_000_000), [])
    }

    func testCustomCargoTargetDeclaresItselfByCacheTag() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let target = root + "/target-issue-20261101"
        try FileManager.default.createDirectory(atPath: target + "/debug", withIntermediateDirectories: true)
        try Data("Signature: 8a477f597d28d172789f06886806bc55\n".utf8).write(to: URL(fileURLWithPath: target + "/CACHEDIR.TAG"))
        try Data(count: 3_000_000).write(to: URL(fileURLWithPath: target + "/debug/a.bin"))
        var options = ScanOptions(); options.home = root; options.categories = [.projects]
        let ctx = ScanContext(options: options, now: Date(), processes: ProcessTable.current(.init(cpu: false)), agentDirs: [],
                              liveClaudeSessions: [], liveClaudeStarts: [])
        var visited = Set<String>(), found: [Projects.Candidate] = []
        Projects.walk(root, depth: 0, ctx: ctx, visited: &visited, into: &found)
        let item = try XCTUnwrap(found.compactMap { Projects.make($0, ctx: ctx) }.first)
        XCTAssertEqual(item.paths, [target])
    }

    func testShortfallSpeaksOnlyWhenMostOfALargeRemovalDidNotReturn() {
        func observation(_ gain: Int64) -> DiskSpaceObservation {
            let at = Date()
            var before = DiskSpaceSnapshot(volumeID: "v", capacityBytes: 100_000_000_000, availableBytes: 10_000_000_000, measuredAt: at)
            before.uptimeNanoseconds = 1
            var after = before; after.availableBytes += gain; after.uptimeNanoseconds = 2
            return DiskSpaceObservation(before: before, after: after)
        }
        XCTAssertNotNil(observation(16_000_000_000).shortfall(expected: 96_000_000_000))
        XCTAssertNil(observation(90_000_000_000).shortfall(expected: 96_000_000_000))
        XCTAssertNil(observation(0).shortfall(expected: 500_000_000))
    }
}
