import Darwin
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

    func checks(running: Set<Int32>, installed: String? = nil) throws -> ConfigChecks {
        let bin = home.appendingPathComponent("bin")
        if installed != nil {
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: bin.appendingPathComponent("codegraph").path, contents: Data("#!/bin/sh\n".utf8),
                                           attributes: [.posixPermissions: 0o755])
        }
        return ConfigChecks(env: DoctorEnvironment(home: home, path: [bin.path], run: { tool, args in
            if tool == "/bin/ps" { return "node codegraph serve \(args.last ?? "")\n" }
            if args == ["--version"] { return installed }
            return nil
        }, executablePath: { running.contains($0) ? "/opt/homebrew/bin/node" : nil }))
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

        var c = try checks(running: [pid], installed: "1.6.0")
        c.checkAgentDatabases()
        XCTAssertEqual(c.findings.count, 1, "the small healthy log is not reported, nor the daemon twice")
        let f = try XCTUnwrap(c.findings.first)
        XCTAssertEqual(f.severity, .error)
        XCTAssertTrue(f.fix?.contains("1.6.0") == true)
        XCTAssertTrue(f.source?.hasSuffix("codegraph.db-wal") == true)
        let item = try XCTUnwrap(c.items.first { $0.id == f.item })
        let fix = try XCTUnwrap(item.actions.first)
        XCTAssertEqual(fix.kind, .fix)
        XCTAssertFalse(fix.bulk, "an upgrade is never applied in bulk")
        XCTAssertEqual(fix.steps, [.run(tool: home.appendingPathComponent("bin/codegraph").path, args: ["upgrade"], cwd: nil),
                                   .kill(pid: pid, args: "node codegraph serve \(pid)")])
    }

    func testOldDaemonIsReportedBeforeItsLogGrows() throws {
        let project = home.appendingPathComponent("p").path
        let pid = getpid()
        try daemon(root: project, pid: pid, version: "1.6.0")
        try daemon(root: project, pid: 999_999, version: "1.5.0")
        var c = try checks(running: [pid], installed: "1.6.2")
        c.checkAgentDatabases()
        XCTAssertEqual(c.findings.map(\.severity), [.warning], "only the process that still runs")
        XCTAssertTrue(c.findings.first?.message.contains("1.6.0") == true)
        let action = try XCTUnwrap(c.items.first?.actions.first)
        XCTAssertTrue(action.bulk, "codegraph is already fixed: only the old process is stopped")
        XCTAssertEqual(action.steps, [.kill(pid: pid, args: "node codegraph serve \(pid)")])

        var upgraded = try checks(running: [pid])
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
        var c = try checks(running: [])
        c.checkAgentDatabases()
        XCTAssertEqual(c.findings.map(\.subject), ["thread_history_1.sqlite"])
        XCTAssertEqual(c.findings.first?.severity, .warning)
    }

    func testLargeWALReportsOnlyObservedSizeAndPreservesFiles() throws {
        try file(".codex/state.sqlite", bytes: 40 << 20)
        try file(".codex/state.sqlite-wal", bytes: 2 << 30)
        let wal = home.appendingPathComponent(".codex/state.sqlite-wal")
        let before = try FileManager.default.attributesOfItem(atPath: wal.path)
        var c = try checks(running: [])
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

    func testDaemonRecordsRespectReadLimitAndSkipSpecialFiles() throws {
        let directory = home.appendingPathComponent(".codegraph/daemons")
        try daemon(root: "/valid", pid: 123, version: "1.6.2")
        let valid = directory.appendingPathComponent("123.json")
        let body = try Data(contentsOf: valid)
        var exact = body
        exact.append(Data(repeating: 0x20, count: 64 * 1024 - body.count))
        try exact.write(to: directory.appendingPathComponent("exact.json"))
        exact.append(0x20)
        try exact.write(to: directory.appendingPathComponent("oversized.json"))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("linked.json"), withDestinationURL: valid)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("directory.json"), withIntermediateDirectories: false)
        let pipe = directory.appendingPathComponent("pipe.json")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)

        let records = ConfigChecks.codegraphDaemons(in: directory)
        XCTAssertEqual(records.count, 3, "valid, linked and exactly-at-limit records remain readable; no pipe writer is needed")
        XCTAssertTrue(records.allSatisfy { $0.root == "/valid" && $0.pid == 123 && $0.version == "1.6.2" })
    }
}
