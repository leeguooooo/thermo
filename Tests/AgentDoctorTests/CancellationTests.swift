import XCTest
import ThermoL10n
@testable import AgentDoctor

final class CancellationTests: XCTestCase {
    func testCancellationDuringLaunchAgentLoopStopsFurtherQueriesAndDropsPartialFindings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let agents = root.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a", "b", "c"] {
            let plist: [String: Any] = ["Label": "fixture." + name, "Program": "/bin/true"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: agents.appendingPathComponent(name + ".plist"))
        }
        let cancellation = DoctorCancellation()
        var queries = 0
        let env = DoctorEnvironment(home: root, path: [], run: { _, _ in
            queries += 1
            cancellation.cancel()
            return nil
        }, cancelled: { cancellation.isCancelled })
        let report = AgentDoctor.run(env)
        XCTAssertEqual(queries, 1)
        XCTAssertEqual(report.cancelled, true)
        XCTAssertTrue(report.findings.isEmpty)
        XCTAssertTrue(report.items.isEmpty)
        XCTAssertTrue(report.processes.isEmpty)
    }
    func testPrecancelledCheckDoesNotLaunchQueriesOrClaimHealthy() {
        let previous = L10n.override
        defer { L10n.override = previous }
        L10n.override = .english
        let cancellation = DoctorCancellation()
        cancellation.cancel()
        var queries = 0
        let env = DoctorEnvironment(home: FileManager.default.temporaryDirectory, path: [], run: { _, _ in queries += 1; return "" },
                                    cancelled: { cancellation.isCancelled })
        let report = AgentDoctor.run(env)
        XCTAssertEqual(queries, 0)
        XCTAssertEqual(report.cancelled, true)
        XCTAssertEqual(report.headline, "check stopped")
    }

    func testDefaultQueryRunnerCancelsItsOwnChild() {
        let start = Date()
        let deadline = start.addingTimeInterval(0.05)
        XCTAssertNil(DoctorEnvironment.runTool("/bin/sleep", ["5"], cancelled: { Date() >= deadline }))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
}
