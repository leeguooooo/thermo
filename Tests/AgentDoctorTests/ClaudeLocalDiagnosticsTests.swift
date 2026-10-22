import XCTest
import AgentCore
@testable import AgentDoctor

final class ClaudeLocalDiagnosticsTests: XCTestCase {
    func fixture(_ body: (URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("claude-local-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try body(home)
    }
    func write(_ home: URL, _ path: String, _ text: String) throws {
        let file = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
    func scan(_ home: URL, env: [String: String] = [:], limit: Int = 1024 * 1024) -> ClaudeLocalReport {
        ClaudeLocalDiagnostics(home: home, environment: env, now: Date(timeIntervalSince1970: 0), applicationRoots: [], maxBytes: limit,
                               processes: { ProcessTable(entries: []) }, processEnvironment: { _ in XCTFail("no process expected"); return nil }, launchValue: { _ in "" }).scan()
    }
    func testExportOmitsIdentifiersCredentialsEndpointsAndSentryValues() throws {
        try fixture { home in
            let userID = String(repeating: "a", count: 64), machineID = String(repeating: "b", count: 64)
            let did = "59987917-8202-44b3-93c0-165b2676a098"
            try write(home, ".claude.json", "{\"userID\":\"\(userID)\",\"machineID\":\"\(machineID)\",\"oauthAccount\":{\"email\":\"private@example.test\"},\"token\":\"SECRET_TOKEN\"}")
            try write(home, "Library/Application Support/Claude/ant-did", Data(did.utf8).base64EncodedString())
            try write(home, "Library/Application Support/Claude/sentry/scope_v3.json", "{\"contexts\":{\"device\":{\"cpu_description\":\"PRIVATE_CPU\"}},\"user\":{\"email\":\"private@example.test\"}}")
            try write(home, ".claude/settings.json", "{\"env\":{\"ANTHROPIC_BASE_URL\":\"https://user:SECRET@private.example.test/v1?key=SECRET\",\"DISABLE_TELEMETRY\":\"0\",\"ANTHROPIC_API_KEY\":\"SECRET_TOKEN\"}}")
            let report = scan(home)
            for secret in [userID, machineID, did, "private@example.test", "PRIVATE_CPU", "SECRET", "private.example.test", home.path] {
                XCTAssertFalse(report.json.contains(secret), secret)
            }
            XCTAssertTrue(report.readOnly); XCTAssertFalse(report.networkPerformed)
            XCTAssertEqual(report.kind, "thermo.claude-local-diagnostics")
            XCTAssertEqual(report.checks.first { $0.id == "sentry.device" }?.status, .observed)
            XCTAssertEqual(report.checks.first { $0.id == "default-claude-config.settings.DISABLE_TELEMETRY" }?.value, "opt-out-requested")
        }
    }
    func testMissingInvalidAndOversizedAreNotHealthy() throws {
        try fixture { home in
            XCTAssertEqual(scan(home).checks.first { $0.id == "default-claude-config.identity" }?.status, .missing)
            try write(home, ".claude.json", "{broken")
            XCTAssertEqual(scan(home).checks.first { $0.id == "default-claude-config.identity" }?.status, .invalid)
            try write(home, ".claude.json", String(repeating: "x", count: 129))
            let report = scan(home, limit: 128)
            XCTAssertEqual(report.checks.first { $0.id == "default-claude-config.identity" }?.status, .limited)
            XCTAssertFalse(report.complete)
        }
    }
    func testSymlinkAndFIFOAreRefusedWithoutReadingOrBlocking() throws {
        try fixture { home in
            let link = home.appendingPathComponent(".claude.json")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/dev/zero"))
            XCTAssertEqual(scan(home).checks.first { $0.id == "default-claude-config.identity" }?.status, .unsupported)
            try FileManager.default.removeItem(at: link)
            XCTAssertEqual(mkfifo(link.path, 0o600), 0)
            XCTAssertEqual(scan(home).checks.first { $0.id == "default-claude-config.identity" }?.status, .unsupported)
        }
    }
    func testVariableSemanticsDifferAndNoRawValueIsEchoed() {
        for value in ["0", "false", "secret-value"] {
            XCTAssertEqual(ClaudeLocalDiagnostics.telemetryState("DISABLE_TELEMETRY", value: value), "opt-out-requested")
        }
        XCTAssertEqual(ClaudeLocalDiagnostics.telemetryState("DO_NOT_TRACK", value: "0"), "opt-out-not-requested")
        XCTAssertEqual(ClaudeLocalDiagnostics.telemetryState("DO_NOT_TRACK", value: "YES"), "opt-out-requested")
        XCTAssertEqual(ClaudeLocalDiagnostics.telemetryState("DO_NOT_TRACK", value: "secret-value"), "unrecognized-boolean")
        XCTAssertEqual(ClaudeLocalDiagnostics.telemetryState("DISABLE_TELEMETRY", value: nil), "unset-or-empty")
        XCTAssertEqual(ClaudeLocalDiagnostics.routeState("ANTHROPIC_BASE_URL", value: "https://api.anthropic.com.evil.test"), "custom-endpoint-configured")
        XCTAssertEqual(ClaudeLocalDiagnostics.routeState("ANTHROPIC_BASE_URL", value: "https://api.anthropic.com"), "official-api-host-configured")
    }
    func testCustomDirectoryAndProcessAccessFailureKeepCoverageHonest() throws {
        try fixture { home in
            let custom = home.appendingPathComponent("custom")
            try write(custom, ".claude.json", "{\"userID\":\"\(String(repeating: "c", count: 64))\"}")
            let report = ClaudeLocalDiagnostics(home: home, environment: ["CLAUDE_CONFIG_DIR": custom.path], applicationRoots: [],
                processes: { ProcessTable(entries: [.init(pid: 123, name: "claude")], inventoryComplete: false) },
                processEnvironment: { _ in nil }, launchValue: { _ in "" }).scan()
            XCTAssertTrue(report.checks.contains { $0.id.hasPrefix("custom-claude-config-") && $0.id.hasSuffix(".userID") && $0.status == .observed })
            XCTAssertEqual(report.checks.first { $0.id == "claude-process-1.environment" }?.status, .unknown)
            XCTAssertEqual(report.checks.first { $0.id == "processes" }?.status, .limited)
            XCTAssertFalse(report.json.contains(custom.path))
            XCTAssertFalse(report.complete)
        }
    }
    func testScanDoesNotModifyInputAndBadSettingsValueIsInvalid() throws {
        try fixture { home in
            let text = "{\"env\":{\"DO_NOT_TRACK\":123}}"
            try write(home, ".claude/settings.json", text)
            let before = try FileManager.default.contentsOfDirectory(atPath: home.path)
            let report = scan(home)
            XCTAssertEqual(report.checks.first { $0.id == "default-claude-config.settings.DO_NOT_TRACK" }?.status, .invalid)
            XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".claude/settings.json"), encoding: .utf8), text)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), before)
        }
    }
}
