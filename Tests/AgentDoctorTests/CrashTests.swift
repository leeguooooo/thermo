import XCTest
@testable import AgentDoctor

final class CrashTests: XCTestCase {
    func report(_ name: String, parent: String, path: String) -> String {
        """
        {"app_name":"\(name)","timestamp":"2026-10-11 21:53:13.00 +0900","bug_type":"309"}
        {
          "procName" : "\(name)",
          "procPath" : "\(path.replacingOccurrences(of: "/", with: "\\/"))",
          "parentProc" : "\(parent)",
          "termination" : {"flags":0,"code":6,"namespace":"SIGNAL","indicator":"Abort trap: 6","byProc":"\(name)"},
          "asi" : {"libsystem_c.dylib":["abort() called"]},
          "threads" : []
        }
        """
    }

    func testRepeatedCrashOfAnAgentChildIsReported() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("crash-\(UUID().uuidString)")
        let dir = home.appendingPathComponent("Library/Logs/DiagnosticReports")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        for i in 0..<3 {
            try report("Python", parent: "claude", path: "/opt/homebrew/Python.app/Contents/MacOS/Python")
                .write(to: dir.appendingPathComponent("Python-\(i).ips"), atomically: true, encoding: .utf8)
        }
        try report("Safari", parent: "launchd", path: "/Applications/Safari.app/Contents/MacOS/Safari")
            .write(to: dir.appendingPathComponent("Safari-1.ips"), atomically: true, encoding: .utf8)
        try report("Safari", parent: "launchd", path: "/Applications/Safari.app/Contents/MacOS/Safari")
            .write(to: dir.appendingPathComponent("Safari-2.ips"), atomically: true, encoding: .utf8)

        let crashes = ConfigChecks.agentCrashes(in: dir, since: Date().addingTimeInterval(-3600))
        XCTAssertEqual(crashes.count, 3, "only programs an agent started")
        XCTAssertEqual(crashes.first?.reason, "Abort trap: 6; abort() called")

        // A server whose script runs under Python is the one blamed.
        let script = home.appendingPathComponent("wrap.py")
        try "#!/usr/bin/env python3\nprint(1)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        var c = ConfigChecks(env: DoctorEnvironment(home: home, path: ["/usr/bin", "/bin"], run: { _, _ in nil }))
        c.item(.mcp, agent: "claude", id: "x", name: "iphone-use", detail: script.path, source: "~/.claude.json")
        c.noteCrashKey(.mcp, agent: "claude", subject: "iphone-use", source: "~/.claude.json", commands: [script.path])
        c.checkCrashes()
        let f = try XCTUnwrap(c.findings.first)
        XCTAssertEqual(f.severity, .warning)
        XCTAssertEqual(f.subject, "iphone-use")
        XCTAssertNotNil(f.item)
        XCTAssertTrue(f.message.contains("3"))
    }

    func testCrashNames() {
        XCTAssertEqual(ConfigChecks.crashName("Python"), "python")
        XCTAssertEqual(ConfigChecks.crashName("/usr/bin/python3.14"), "python")
        XCTAssertEqual(ConfigChecks.crashName("node"), "node")
    }
}
