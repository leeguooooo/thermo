import XCTest
import ThermoL10n
@testable import AgentDoctor

final class ProcessCompletenessTests: XCTestCase {
    var home: URL!
    override func setUpWithError() throws {
        L10n.override = .english
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { L10n.override = nil; try? FileManager.default.removeItem(at: home) }

    func testMissingProcessListIsAVisibleIncompleteItem() {
        let env = DoctorEnvironment(home: home, run: { _, _ in nil })
        let report = AgentDoctor.run(env)
        let item = report.items.first { $0.name == "Process list" }
        XCTAssertEqual(item?.severity, .warning)
        XCTAssertTrue(item?.actions.isEmpty == true)
        XCTAssertTrue(report.findings.contains { $0.message.contains("incomplete") })
    }

    func testUnknownOwnershipNeverOffersStopActions() throws {
        let binary = home.appendingPathComponent("fixture-mcp").path
        FileManager.default.createFile(atPath: binary, contents: Data())
        for ownership in [nil, "malformed launchctl output"] as [String?] {
            let env = DoctorEnvironment(home: home, run: { tool, _ in
                tool == "/bin/ps" ? "42 1 95.0 2048 25:00 \(binary) serve" : ownership
            }, executablePath: { _ in binary })
            let report = AgentDoctor.run(env)
            XCTAssertEqual(report.items.first { $0.name == "Process ownership" }?.severity, .warning)
            XCTAssertTrue(report.items.allSatisfy { $0.actions.isEmpty })
            XCTAssertTrue(report.processes.allSatisfy { $0.detached == 0 })
            XCTAssertTrue(report.findings.contains { $0.message.contains("95% CPU") })
        }
    }

    func testCodexSessionIsNeverAnEndProcessCandidate() throws {
        let binary = home.appendingPathComponent("codex").path
        FileManager.default.createFile(atPath: binary, contents: Data())
        let env = DoctorEnvironment(home: home, run: { tool, _ in
            tool == "/bin/ps" ? "42 1 95.0 2048 25:00 \(binary) run" : "services = {\n}"
        }, executablePath: { _ in binary })
        let report = AgentDoctor.run(env)
        let session = try XCTUnwrap(report.items.first { $0.name.hasPrefix("codex") })
        XCTAssertTrue(session.actions.isEmpty)
    }
}
