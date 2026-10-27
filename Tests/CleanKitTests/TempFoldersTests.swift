@testable import CleanKit
import AgentCore
import ThermoL10n
import XCTest

final class TempFoldersTests: XCTestCase {
    var root: String!
    let now = Date()

    override func setUp() {
        L10n.override = .english
        FS.countsStatusChanges = false  // ctime cannot be backdated in a fixture
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tempfolders-" + UUID().uuidString).path
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: root); L10n.override = nil; FS.countsStatusChanges = true }

    func folder(_ name: String, bytes: Int = 4096, age: TimeInterval, gitFile: Bool = false) {
        let path = root + "/" + name
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path + "/out.bin", contents: Data(repeating: 7, count: bytes))
        if gitFile { FileManager.default.createFile(atPath: path + "/.git", contents: Data("gitdir: /repo/.git/worktrees/x\n".utf8)) }
        let date = now.addingTimeInterval(-age)
        for p in [path + "/out.bin", path + "/.git", path] where FileManager.default.fileExists(atPath: p) {
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: p)
        }
    }

    func ctx(_ entries: [AgentProcess] = []) -> ScanContext {
        ScanContext(options: ScanOptions(), now: now, processes: ProcessTable(entries: entries), agentDirs: [], liveClaudeSessions: [])
    }

    func testPatterns() {
        XCTAssertEqual(TempFolders.pattern("iphone-use-3f9a2c-build"), "iphone-use-*-build")
        XCTAssertEqual(TempFolders.pattern("iphone-use-12-build"), "iphone-use-*-build")
        XCTAssertEqual(TempFolders.pattern("thermo-release-audit-20261027-0912"), "thermo-release-audit-*")
        XCTAssertEqual(TempFolders.pattern("wechat-receive-test-a1b2c3d4"), "wechat-receive-test-*")
        XCTAssertEqual(TempFolders.pattern("rea-E621F3A4-1C2B-4D5E-8F90-123456789ABC"), "rea-*")
        XCTAssertEqual(TempFolders.pattern("site-public"), "site-public")
        XCTAssertEqual(TempFolders.producer("iphone-use-ax-boundary-physical-1"), "iphone-use")
        XCTAssertEqual(TempFolders.producer("mu-native-3"), "mu")
        XCTAssertEqual(TempFolders.producer("tmp.Ab12"), "tmp")
    }

    func testGroupsOldToolFoldersAndKeepsRecentOpenAndReserved() {
        for i in 0..<6 { folder("iphone-use-\(i)abc12-build", bytes: 20_000_000, age: 10 * 3600) }
        folder("iphone-use-99-build", bytes: 20_000_000, age: 600)          // still being written
        folder("rea-busy-1", bytes: 80_000_000, age: 20 * 3600)             // a process works in it
        folder("thermo-release-audit-20261027", bytes: 60_000_000, age: 30 * 3600)
        folder("com.apple.launchd.x", bytes: 60_000_000, age: 99 * 3600)
        folder("claude-501", bytes: 60_000_000, age: 99 * 3600)
        folder("wt-feature-123", age: 40 * 3600, gitFile: true)
        let worker = AgentProcess(pid: 77, name: "rea", cwd: root + "/rea-busy-1/sub")
        let items = TempFolders.scan(ctx([worker]), roots: [root], open: nil)
        let build = items.first { $0.id == "temp/iphone-use" }
        XCTAssertEqual(build?.paths.count, 6, "the folder written ten minutes ago is kept")
        XCTAssertEqual(build?.safety, .review)
        XCTAssertNotNil(items.first { $0.id == "temp/thermo" })
        XCTAssertFalse(items.contains { $0.paths.contains { $0.contains("rea-busy") } })
        XCTAssertFalse(items.contains { $0.paths.contains { $0.contains("com.apple") || $0.contains("claude-501") } })
        let wt = items.first { $0.id == "temp-worktrees" }
        XCTAssertEqual(wt?.category, .agentWorktrees, "worktrees go through git worktree removal, which keeps dirty ones")
        XCTAssertEqual(wt?.paths, [root + "/wt-feature-123"])
    }

    func testGuardAllowsOnlyOwnTopLevelTempFolders() throws {
        let g = Guard()
        let mine = "/private/tmp/thermo-guard-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: mine + "/inner", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: mine) }
        XCTAssertNil(g.refusal(mine))
        XCTAssertNotNil(g.refusal(mine + "/inner"), "only whole top-level folders")
        XCTAssertNotNil(g.refusal("/private/tmp"))
        XCTAssertNotNil(g.refusal("/private/tmp/claude-\(getuid())"))
        XCTAssertNotNil(g.refusal("/private/tmp/com.apple.launchd.abc"))
    }
}
