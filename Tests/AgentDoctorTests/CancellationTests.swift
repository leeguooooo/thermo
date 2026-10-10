import XCTest
import ThermoL10n
@testable import AgentDoctor

final class CancellationTests: XCTestCase {
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
