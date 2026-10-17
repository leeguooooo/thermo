import XCTest
import CleanKit
@testable import thermo

final class CleanReportStatusTests: XCTestCase {
    func report(cancelled: Bool = false, denied: [String] = []) -> ScanReport {
        .init(items: [], denied: denied, started: Date(timeIntervalSince1970: 100), duration: 1, cancelled: cancelled)
    }
    func testEveryFormatSignalsPartialAfterEmittingCancelledReport() throws {
        for flags in [[], ["--json"], ["--csv"], ["--stream"]] {
            let command = CleanCommand(app: App(args: try Args(flags)))
            var output: [String] = []
            XCTAssertThrowsError(try command.writeReport(report(cancelled: true), categories: nil, write: { output.append($0) })) { error in
                XCTAssertEqual((error as? CLIError)?.exitCode, 3)
            }
            if flags.contains("--json") {
                let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.joined().utf8)) as? [String: Any])
                XCTAssertEqual(value["cancelled"] as? Bool, true)
            } else if flags.contains("--csv") {
                XCTAssertEqual(output.first, "id,category,safety,bytes,files,last_used,title,detail,blocked")
            } else if flags.contains("--stream") { XCTAssertTrue(output.isEmpty, "scanner owns stream events") }
            else { XCTAssertFalse(output.joined().contains("nothing to clean")) }
        }
    }
    func testUnreadableEmptyReportDoesNotClaimNothingToClean() throws {
        let command = CleanCommand(app: App(args: try Args([])))
        var output: [String] = []
        try command.writeReport(report(denied: ["/fixture/denied"]), categories: nil, write: { output.append($0) })
        XCTAssertTrue(output.joined().contains("no verified findings"))
        XCTAssertFalse(output.joined().contains("nothing to clean"))
    }
    func testConfirmedEmptyCSVAndJSONRemainSuccessful() throws {
        for flags in [[], ["--json"], ["--csv"], ["--stream"]] {
            let command = CleanCommand(app: App(args: try Args(flags)))
            XCTAssertNoThrow(try command.writeReport(report(), categories: nil, write: { _ in }))
        }
    }
    func testAdvertisedScanCSVPassesContractButMutationAndOverviewCSVStayRejected() throws {
        XCTAssertTrue(CommandHelp.capabilities.first { $0.command == "clean" }?.structuredFormats.contains("csv") == true)
        XCTAssertNoThrow(try CommandContract.validate(Args(["clean", "--csv"])))
        XCTAssertNoThrow(try CommandContract.validate(Args(["clean", "browsers", "--csv"])))
        XCTAssertThrowsError(try CommandContract.validate(Args(["clean", "run", "safe", "--csv"])))
        XCTAssertThrowsError(try CommandContract.validate(Args(["clean", "overview", "--csv"])))
    }
}
