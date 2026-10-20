import XCTest
import AgentCore
@testable import thermo

final class AudioInputCommandTests: XCTestCase {
    private func operation(_ argv: [String]) throws -> AppControlCommand.Operation {
        let args = try Args(["audio-input"] + argv)
        return try AppControlCommand.operation(command: "audio-input", rest: Array(args.positionals.dropFirst()), args: args)
    }
    func testInspectionAndMutatingAppCommandsHaveSeparateContracts() throws {
        let args = try Args(["audio-input", "inspect", "--json", "--limit", "2"])
        XCTAssertNoThrow(try CommandContract.validate(args)); XCTAssertNoThrow(try AudioInputCommand.validateInspection(args))
        XCTAssertEqual(try AudioInputCommand.limit(args.options["limit"]), 2)
        XCTAssertFalse(try operation(["status"]).mutates)
        XCTAssertEqual(try operation(["on", "--dry-run"]).action, "audio-input.on")
        XCTAssertTrue(try operation(["off"]).mutates)
        XCTAssertEqual(try operation(["mute", "--app", "test.recorder"]).arguments, ["app":"test.recorder"])
        for sub in ["on", "off", "mute", "unmute"] {
            let argv = ["audio-input", sub, "--dry-run", "--yes", "--json"] + (["mute", "unmute"].contains(sub) ? ["--app", "test.recorder"] : [])
            XCTAssertNoThrow(try CommandContract.validate(Args(argv)), sub)
        }
    }
    func testInspectionRejectsPreferenceFlagsAndInvalidLimitsBeforeReading() throws {
        for argv in [["audio-input", "--dry-run"], ["audio-input", "inspect", "--app", "test.recorder"]] {
            XCTAssertThrowsError(try AudioInputCommand.validateInspection(Args(argv)))
        }
        for value in ["0", "-1", "4097", "NaN"] { XCTAssertThrowsError(try AudioInputCommand.limit(value)) }
        XCTAssertEqual(try AudioInputCommand.limit(nil), 64)
    }
    func testAppOperationsRejectWrongOptionsMissingKeysAndExtraPositionals() {
        for argv in [["mute"], ["on", "--app", "x"], ["status", "--limit", "1"], ["mute", "--app", "x\n"], ["off", "extra"]] {
            XCTAssertThrowsError(try operation(argv))
        }
    }
    func testCapabilityInventoryDeclaresExecutionBoundariesAndFormats() throws {
        let inspect = try XCTUnwrap(CommandHelp.capabilities.first { $0.command == "audio-input inspect" })
        XCTAssertEqual(inspect.execution, "cli"); XCTAssertFalse(inspect.supportsDryRun)
        XCTAssertEqual(inspect.structuredFormats, ["json"])
        XCTAssertEqual(CommandHelp.capabilities.first { $0.command == "audio-input on" }?.execution, "app")
        XCTAssertTrue(CommandHelp.text(for: ["audio-input"]).contains("without recording"))
        XCTAssertThrowsError(try CommandContract.validate(Args(["audio-input", "inspect", "--csv"])))
    }
    func testHumanOutputEscapesTerminalControlCharactersAndPreservesUnknownState() {
        let client = AudioInputClient(objectID: 1, process: .init(pid: 5, uid: 501,
            started: Date(), executable: "/Recorder\u{1b}[31m"), bundleID: "test.recorder",
            devices: [.init(id: 2, uid: "private", name: "Mic\u{1b}]52;unsafe")])
        let report = AudioInputReport(observation: .init(clients: [client], issues: ["unreadable"]), source: "test")
        let text = AudioInputCommand.text(report)
        XCTAssertTrue(text.contains("Audio input: unknown")); XCTAssertTrue(text.contains("PID 5"))
        XCTAssertFalse(text.contains("\u{1b}")); XCTAssertFalse(text.contains("private"))
    }
}
