import XCTest
@testable import AgentDoctor

final class AgentDatabaseTests: XCTestCase {
    var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("dblog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: home) }

    /// Sparse files: the check reads sizes only.
    func file(_ rel: String, bytes: Int64) throws {
        let url = home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: UInt64(bytes))
        try h.close()
    }

    func daemon(root: String, pid: Int32, version: String) throws {
        let url = home.appendingPathComponent(".codegraph/daemons/\(pid).json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"root":"\#(root)","pid":\#(pid),"version":"\#(version)"}"#.write(to: url, atomically: true, encoding: .utf8)
    }

    func checks(running: Set<Int32>) -> ConfigChecks {
        ConfigChecks(env: DoctorEnvironment(home: home, path: [], run: { _, _ in nil },
                                            executablePath: { running.contains($0) ? "/opt/homebrew/bin/node" : nil }))
    }

    func testStuckCodegraphLogIsFoundAndBlamesTheOldDaemon() throws {
        let project = home.appendingPathComponent("wechat-project").path
        try file("wechat-project/.codegraph/codegraph.db", bytes: 2 << 30)
        try file("wechat-project/.codegraph/codegraph.db-wal", bytes: 19 << 30)
        try file("small/.codegraph/codegraph.db", bytes: 300 << 20)
        try file("small/.codegraph/codegraph.db-wal", bytes: 4 << 20)
        try #"{"projects":{"\#(home.appendingPathComponent("small").path)":{}}}"#
            .write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let pid = getpid()
        try daemon(root: project, pid: pid, version: "1.6.0")

        var c = checks(running: [pid])
        let item = c.item(.mcp, agent: "claude", id: "codegraph", name: "codegraph", detail: "codegraph serve", source: "~/.claude.json")
        c.checkAgentDatabases()
        XCTAssertEqual(c.findings.count, 1, "the small healthy log is not reported, nor the daemon twice")
        let f = try XCTUnwrap(c.findings.first)
        XCTAssertEqual(f.severity, .error)
        XCTAssertEqual(f.item, item)
        XCTAssertTrue(f.fix?.contains("1.6.0") == true)
        XCTAssertTrue(f.source?.hasSuffix("codegraph.db-wal") == true)
    }

    func testOldDaemonIsReportedBeforeItsLogGrows() throws {
        let project = home.appendingPathComponent("p").path
        let pid = getpid()
        try daemon(root: project, pid: pid, version: "1.6.0")
        try daemon(root: project, pid: 999_999, version: "1.5.0")
        var c = checks(running: [pid])
        c.checkAgentDatabases()
        XCTAssertEqual(c.findings.map(\.severity), [.warning], "only the process that still runs")
        XCTAssertTrue(c.findings.first?.message.contains("1.6.0") == true)

        var upgraded = checks(running: [pid])
        try daemon(root: project, pid: pid, version: "1.6.2")
        try? FileManager.default.removeItem(at: home.appendingPathComponent(".codegraph/daemons/999999.json"))
        upgraded.checkAgentDatabases()
        XCTAssertTrue(upgraded.findings.isEmpty)
    }

    func testStuckCodexLog() throws {
        try file(".codex/thread_history_1.sqlite", bytes: 1 << 30)
        try file(".codex/thread_history_1.sqlite-wal", bytes: 3 << 30)
        try file(".codex/state_5.sqlite", bytes: 40 << 20)
        try file(".codex/state_5.sqlite-wal", bytes: 4 << 20)
        var c = checks(running: [])
        c.checkAgentDatabases()
        XCTAssertEqual(c.findings.map(\.subject), ["thread_history_1.sqlite"])
        XCTAssertEqual(c.findings.first?.severity, .warning)
    }

    func testLargeWALReportsOnlyObservedSizeAndPreservesFiles() throws {
        try file(".codex/state.sqlite", bytes: 40 << 20)
        try file(".codex/state.sqlite-wal", bytes: 2 << 30)
        let wal = home.appendingPathComponent(".codex/state.sqlite-wal")
        let before = try FileManager.default.attributesOfItem(atPath: wal.path)
        var c = checks(running: [])
        c.checkAgentDatabases()
        let finding = try XCTUnwrap(c.findings.first)
        XCTAssertTrue(finding.message.contains("this snapshot cannot establish"))
        XCTAssertFalse(finding.message.contains("keeps growing"))
        XCTAssertTrue(finding.fix?.contains("Never delete") == true)
        XCTAssertTrue(finding.fix?.contains("recheck") == true)
        let after = try FileManager.default.attributesOfItem(atPath: wal.path)
        XCTAssertEqual(before[.size] as? NSNumber, after[.size] as? NSNumber)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/state.sqlite").path))
    }

    func testVersionsBeforeTheFix() {
        XCTAssertTrue(ConfigChecks.codegraphHasLogBug("1.6.0"))
        XCTAssertTrue(ConfigChecks.codegraphHasLogBug("v1.5.9"))
        XCTAssertFalse(ConfigChecks.codegraphHasLogBug("1.6.1"))
        XCTAssertFalse(ConfigChecks.codegraphHasLogBug("2.0.0"))
        XCTAssertFalse(ConfigChecks.codegraphHasLogBug(""))
    }
}
