import XCTest
import AgentCore
@testable import CleanKit

final class CommandAccountingTests: XCTestCase {
    var home = ""
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("command-accounting-" + UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(atPath: home) }
    func run(_ commands: [[String]], measure: [String]? = nil) -> CleanResult {
        Cleaner.clean(CleanItem(id: "fixture-command", category: .devCaches, title: "fixture", safety: .safe,
            bytes: 1_000_000_000, commands: commands, measure: measure), mode: .permanent,
            guard: Guard(home: home), processTable: .init(entries: []))
    }
    func fixture() throws -> String {
        let path = home + "/payload"
        try Data(repeating: 17, count: 65536).write(to: URL(fileURLWithPath: path))
        return path
    }
    func testSuccessfulNoOpCannotClaimScannedSize() throws {
        let result = run([["/usr/bin/true"]])
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertEqual(result.bytes, 0)
        XCTAssertEqual(result.bytesIncomplete, true)
        let history = try XCTUnwrap(OperationJournal.read(home: home).first)
        XCTAssertEqual(history.bytesIncomplete, true)
    }
    func testMeasuredNoOpReportsZeroWithoutUnknown() throws {
        let path = try fixture()
        let result = run([["/usr/bin/true"]], measure: [path])
        XCTAssertEqual(result.bytes, 0)
        XCTAssertNotEqual(result.bytesIncomplete, true)
        XCTAssertTrue(FS.exists(path))
    }
    func testFailedCommandStillAccountsForObservedRemoval() throws {
        let path = try fixture(), before = FS.commandSize([path])
        XCTAssertGreaterThan(before.bytes, 0)
        // A single command can remove data before failing. Only this test's own file is touched.
        let result = run([["/bin/sh", "-c", "rm -- \"$1\"; exit 7", "fixture", path]], measure: [path])
        XCTAssertFalse(FS.exists(path))
        XCTAssertFalse(result.failed.isEmpty)
        XCTAssertEqual(result.bytes, before.bytes)
        XCTAssertEqual(result.outcome, "partial")
        XCTAssertFalse(result.partialCommands?.isEmpty ?? true)
        let history = try XCTUnwrap(OperationJournal.read(home: home).first)
        XCTAssertEqual(history.bytes, before.bytes)
        XCTAssertEqual(history.outcome, "partial")
    }
    func testEarlierSuccessfulCommandIsMeasuredWhenLaterCommandFails() throws {
        let path = try fixture(), before = FS.commandSize([path])
        let result = run([["/bin/rm", "--", path], ["/usr/bin/false"]], measure: [path])
        XCTAssertEqual(result.bytes, before.bytes)
        XCTAssertEqual(result.outcome, "partial")
        XCTAssertEqual(result.removed.count, 1)
    }
    func testEmptyMeasurementListCannotProveZero() {
        let result = run([["/usr/bin/true"]], measure: [])
        XCTAssertEqual(result.bytes, 0)
        XCTAssertEqual(result.bytesIncomplete, true)
    }
    func testUnreadableMeasurementCannotProveZero() throws {
        let path = try fixture()
        let result = run([["/usr/bin/true"]], measure: [path + "/not-a-directory"])
        XCTAssertEqual(result.bytes, 0)
        XCTAssertEqual(result.bytesIncomplete, true)
    }
    func testFailedCommandRemovingEmptyFileIsStillPartial() throws {
        let path = home + "/empty"
        try Data().write(to: URL(fileURLWithPath: path))
        let result = run([["/bin/sh", "-c", "rm -- \"$1\"; exit 7", "fixture", path]], measure: [path])
        XCTAssertFalse(FS.exists(path))
        XCTAssertEqual(result.bytes, 0)
        XCTAssertEqual(result.outcome, "partial")
        XCTAssertFalse(result.partialCommands?.isEmpty ?? true)
    }
    func testFailedUnmeasuredCommandPreservesUnknown() {
        let result = run([["/usr/bin/false"]])
        XCTAssertEqual(result.bytes, 0)
        XCTAssertEqual(result.bytesIncomplete, true)
        XCTAssertFalse(result.failed.isEmpty)
    }
}
