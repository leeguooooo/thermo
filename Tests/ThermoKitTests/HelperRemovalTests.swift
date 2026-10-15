import XCTest
@testable import ThermoKit

final class HelperRemovalTests: XCTestCase {
    enum Fault: Error { case injected }
    let confirmed = FanAutoRecoveryReport(unconfirmed: [], requestErrors: [])

    func testPreparationFencesBeforeClearingAndPersistsBeforeHardwareConfirmation() throws {
        let gate = HelperRemovalGuard()
        var events: [String] = []
        try gate.prepare(token: "fixture", clearPolicies: {
            XCTAssertTrue(gate.isPreparing)
            events.append("clear")
        }, savePolicies: { events.append("save") }, restoreFans: {
            events.append("fans"); return self.confirmed
        }, restoreSleep: { events.append("sleep") })
        XCTAssertEqual(events, ["clear", "save", "fans", "sleep"])
        XCTAssertTrue(gate.isPreparing, "successful preparation fences until removal or cancellation")
        try gate.cancel(token: "fixture")
        XCTAssertFalse(gate.isPreparing)
        XCTAssertEqual(events.count, 4, "cancellation must not restore old policies")
    }

    func testPersistenceFailureStillAttemptsBothRestorationsAndBlocksRemoval() {
        let gate = HelperRemovalGuard()
        var events: [String] = []
        XCTAssertThrowsError(try gate.prepare(token: "fixture", clearPolicies: { events.append("clear") }, savePolicies: {
            throw Fault.injected
        }, restoreFans: { events.append("fans"); return self.confirmed }, restoreSleep: { events.append("sleep") }))
        XCTAssertEqual(events, ["clear", "fans", "sleep"])
        XCTAssertTrue(gate.isPreparing)
    }

    func testUnknownFanOrSleepRestorationCannotPrepareRemoval() {
        for sleepFails in [false, true] {
            let gate = HelperRemovalGuard()
            XCTAssertThrowsError(try gate.prepare(token: "fixture", clearPolicies: {}, savePolicies: {}, restoreFans: {
                sleepFails ? self.confirmed : .init(unconfirmed: ["manual mode remains"], requestErrors: [])
            }, restoreSleep: { if sleepFails { throw Fault.injected } }))
            XCTAssertTrue(gate.isPreparing)
        }
    }

    func testFailedPreparationNeverCallsRemovalAndCancelsTheFence() {
        var events: [String] = []
        XCTAssertThrowsError(try HelperRemovalOperation.run(prepare: { events.append("prepare"); throw Fault.injected },
            remove: { XCTFail("must not remove") }, cancel: { events.append("cancel") }))
        XCTAssertEqual(events, ["prepare", "cancel"])
    }

    func testRemovalCancellationReleasesFenceAndRetainsOriginalFailure() {
        var events: [String] = []
        XCTAssertThrowsError(try HelperRemovalOperation.run(prepare: { events.append("prepare") },
            remove: { events.append("remove"); throw Fault.injected }, cancel: { events.append("cancel") })) { error in
                XCTAssertTrue(error is Fault)
            }
        XCTAssertEqual(events, ["prepare", "remove", "cancel"])
        XCTAssertThrowsError(try HelperRemovalOperation.run(prepare: {}, remove: { throw Fault.injected },
            cancel: { throw Fault.injected })) { error in
                XCTAssertTrue(String(describing: error).contains("could not release removal preparation"))
            }
    }

    func testSuccessfulRemovalDoesNotReconnectToStoppedHelper() throws {
        var events: [String] = []
        try HelperRemovalOperation.run(prepare: { events.append("prepare") }, remove: { events.append("remove") },
            cancel: { XCTFail("must not reconnect after removal") })
        XCTAssertEqual(events, ["prepare", "remove"])
    }

    func testCompetingRemovalCannotClearAnotherCallersFence() throws {
        let gate = HelperRemovalGuard()
        try gate.prepare(token: "first", clearPolicies: {}, savePolicies: {}, restoreFans: { self.confirmed })
        XCTAssertThrowsError(try gate.prepare(token: "second", clearPolicies: { XCTFail("must not mutate") },
            savePolicies: {}, restoreFans: { XCTFail("must not write hardware"); return self.confirmed }))
        XCTAssertThrowsError(try gate.cancel(token: "second"))
        XCTAssertTrue(gate.isPreparing)
        try gate.cancel(token: "first")
        XCTAssertFalse(gate.isPreparing)
    }

    func testRemovalShellStopsOnBootoutFailureAndOnlyDeletesAfterSuccess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("quoted ' file")
        try Data("owned fixture".utf8).write(to: file)
        func run(_ bootout: String, _ paths: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", HelperInstaller.removalScript(bootout: bootout, paths: paths)]
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            return process.terminationStatus
        }
        XCTAssertNotEqual(try run("false", [file.path]), 0)
        XCTAssertEqual(try Data(contentsOf: file), Data("owned fixture".utf8))
        XCTAssertEqual(try run("true", [file.path]), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNotEqual(try run("true", [root.path]), 0, "rm failure must not be hidden by a trailing success command")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }
}
