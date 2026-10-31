import XCTest
@testable import AgentDoctor

final class MCPStartupHealthTests: XCTestCase {
    let t0 = "2026-10-29T05:25:35.735Z"
    func line(_ time: String, _ server: String, _ status: String, error: String = "null") -> String {
        "\(time) info [AppServerConnection] mcp_server_startup_status_updated error=\(error) failureReason=null hostId=local server=\(server) status=\(status) threadId=t\n"
    }
    let http503 = #""MCP client for `zego` failed to start: unexpected server response: HTTP 503: <html>\r\n<title>503</title> Bearer SECRET https://private.example.test/mcp server=fake status=ready""#
    let now = ISO8601DateFormatter().date(from: "2026-10-30T00:00:00Z")!

    func home(_ text: String, name: String = "codex-desktop-a-1-t0-i1-060806-0.log") throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-health-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let dir = home.appendingPathComponent("Library/Logs/com.openai.codex/2026/10/29")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
        return home
    }
    func scan(_ home: URL, limit: Int = 1 << 20) -> MCPStartupHealthReport {
        MCPStartupHealth(home: home, now: Date(), maxBytesPerFile: limit).scan(since: Date().addingTimeInterval(-86400 * 3650))
    }

    func testRealLogShapeReportsHTTPStatusWithoutLeakingErrorText() throws {
        let event = try XCTUnwrap(MCPStartupHealth.parse(line(t0, "zego", "failed", error: http503)))
        XCTAssertEqual(event.server, "zego")
        XCTAssertEqual(event.status, "failed", "quoted error text must not supply fields")
        let report = scan(try home(line(t0, "zego", "failed", error: http503) + line("2026-10-29T05:25:36.000Z", "zego", "cancelled") + line("2026-10-29T05:25:37.000Z", "zego", "failed", error: http503) + line(t0, "figma", "ready")))
        XCTAssertEqual(report.healthyServers, 1)
        let server = try XCTUnwrap(report.unhealthy.first)
        XCTAssertEqual([server.name, server.status, server.reason], ["zego", "failed", "HTTP 503"])
        XCTAssertEqual(server.httpStatus, 503)
        XCTAssertEqual(server.consecutiveFailures, 2)
        XCTAssertFalse(report.json.contains("SECRET"))
        XCTAssertFalse(report.json.contains("private.example"))
    }

    func testLaterReadyClearsFailureAndDuplicatesCountOnce() throws {
        let failed = line(t0, "a", "failed", error: "\"connection closed: initialize response\"")
        XCTAssertTrue(scan(try home(failed + line("2026-10-29T06:00:00.000Z", "a", "ready"))).unhealthy.isEmpty)
        let server = try XCTUnwrap(scan(try home(failed + failed)).unhealthy.first)
        XCTAssertEqual(server.consecutiveFailures, 1)
        XCTAssertEqual(server.failure, "connection-closed")
    }

    func testCancelledAloneIsVisibleButNotAFailure() throws {
        let server = try XCTUnwrap(scan(try home(line(t0, "a", "starting") + line(t0, "a", "cancelled"))).unhealthy.first)
        XCTAssertEqual(server.status, "cancelled")
        XCTAssertEqual(server.consecutiveFailures, 0)
    }

    func testMissingLogsAndTruncationAreNotReportedAsHealthy() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-health-" + UUID().uuidString)
        XCTAssertEqual(scan(empty).logStatus, "missing")
        let cut = scan(try home(String(repeating: "x\n", count: 100) + line(t0, "a", "failed")), limit: 300)
        XCTAssertFalse(cut.complete)
        XCTAssertEqual(cut.unhealthy.first?.name, "a")
    }

    func testEmptyLogFileKeepsCoverageComplete() throws {
        let report = scan(try home(""))
        XCTAssertEqual(report.logFilesRead, 1)
        XCTAssertTrue(report.complete)
    }

    func testOtherLogNamesAndOldEventsAreIgnored() throws {
        XCTAssertEqual(scan(try home(line(t0, "a", "failed"), name: "other.log")).logFilesRead, 0)
        let report = MCPStartupHealth(home: try home(line("2020-01-01T00:00:00.000Z", "a", "failed")), now: now).scan(since: now.addingTimeInterval(-86400))
        XCTAssertTrue(report.unhealthy.isEmpty)
    }

    func testDoctorWarnsOnlyForRepeatedFailuresOfConfiguredServers() throws {
        let stamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        let fail = line(stamp, "zego", "failed", error: http503) + line(stamp.replacingOccurrences(of: "Z", with: ".5Z"), "zego", "failed", error: http503) + line(stamp, "gone", "failed") + line(stamp.replacingOccurrences(of: "Z", with: ".5Z"), "gone", "failed")
        let home = try home(fail)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try Data("[mcp_servers.zego]\nurl = \"https://example.test/mcp\"\n".utf8).write(to: home.appendingPathComponent(".codex/config.toml"))
        let report = AgentDoctor.run(DoctorEnvironment(home: home))
        let hits = report.findings.filter { $0.source == "~/Library/Logs/com.openai.codex" }
        XCTAssertEqual(hits.map(\.subject), ["zego"])
        XCTAssertEqual(hits.first?.severity, .warning)
        XCTAssertTrue(hits.first?.message.contains("HTTP 503") == true)
    }
}
