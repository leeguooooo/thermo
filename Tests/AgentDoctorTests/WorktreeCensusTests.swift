import XCTest
@testable import AgentDoctor
import ThermoL10n

final class WorktreeCensusTests: XCTestCase {
    var home: URL!

    override func setUpWithError() throws {
        L10n.override = .english  // assertions read English messages whatever the machine's language
        home = FileManager.default.temporaryDirectory.appendingPathComponent("wt-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: home) }

    /// A main checkout with `count` registered worktrees, the first `missing` of them already deleted.
    func repository(_ name: String, count: Int, missing: Int) throws -> String {
        let repo = home.appendingPathComponent(name).path
        for i in 0..<count {
            let wt = home.appendingPathComponent(".codex/artifacts/\(name)-\(i)/source").path
            let admin = repo + "/.git/worktrees/w\(i)"
            try FileManager.default.createDirectory(atPath: admin, withIntermediateDirectories: true)
            try (wt + "/.git\n").write(toFile: admin + "/gitdir", atomically: true, encoding: .utf8)
            if i >= missing {
                try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
                try "gitdir: \(admin)\n".write(toFile: wt + "/.git", atomically: true, encoding: .utf8)
            }
        }
        return repo
    }

    func testRepositoriesWithManyWorktreesAreReportedWithAPruneForMissingOnes() throws {
        let busy = try repository("thermo", count: 49, missing: 4)
        let calm = try repository("tidy", count: 3, missing: 0)
        // Claude knows one through a linked worktree, Codex the other directly.
        try #"{"projects":{"\#(home.appendingPathComponent(".codex/artifacts/thermo-7/source").path)":{}}}"#
            .write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        try "[projects.\"\(calm)\"]\ntrust_level = \"trusted\"\n"
            .write(to: home.appendingPathComponent(".codex/config.toml"), atomically: true, encoding: .utf8)

        var c = ConfigChecks(env: DoctorEnvironment(home: home, path: ["/usr/bin"], run: { _, _ in nil }))
        c.checkWorktrees()
        XCTAssertEqual(c.findings.count, 1, "three worktrees are fine")
        let f = try XCTUnwrap(c.findings.first)
        XCTAssertEqual(f.area, .worktrees)
        XCTAssertEqual(f.severity, .warning)
        XCTAssertTrue(f.message.contains("49") && f.message.contains("4"))
        let item = try XCTUnwrap(c.items.first { $0.id == f.item })
        XCTAssertEqual(item.actions.first?.steps, [.run(tool: "/usr/bin/git", args: ["-C", busy, "worktree", "prune"], cwd: nil)])
    }

    func testCensusCountsRegisteredAndMissing() throws {
        let repo = try repository("r", count: 5, missing: 2)
        let census = try XCTUnwrap(ConfigChecks.worktreeCensus(repo))
        XCTAssertEqual(census.worktrees.count, 5)
        XCTAssertEqual(census.missing.count, 2)
        XCTAssertNil(ConfigChecks.worktreeCensus(home.appendingPathComponent(".codex/artifacts/r-3/source").path), "a linked worktree is not a main checkout")
        XCTAssertEqual(ConfigChecks.mainCheckout(home.appendingPathComponent(".codex/artifacts/r-3/source/Sources").path, home: home.path), repo)
    }
}
