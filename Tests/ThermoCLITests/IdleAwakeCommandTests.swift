import XCTest
@testable import thermo

final class IdleAwakeCommandTests: XCTestCase {
    func operation(_ values: [String]) throws -> AppControlCommand.Operation {
        let args = try Args(["keep-awake"] + values)
        try CommandContract.validate(args)
        return try AppControlCommand.operation(command:"keep-awake", rest:Array(args.positionals.dropFirst()), args:args)
    }
    func testTimedAndManualRequestsAreExplicitAndAppOwned() throws {
        let timed = try operation(["start","--mode","tasks","--seconds","90","--dry-run","--json"])
        XCTAssertEqual(timed.action,"keep-awake.start"); XCTAssertEqual(timed.arguments,["mode":"tasks","seconds":"90"]); XCTAssertTrue(timed.mutates)
        let manual = try operation(["start","--duration","manual"])
        XCTAssertEqual(manual.arguments,["mode":"both","duration":"manual"])
        XCTAssertFalse(try operation(["status"]).mutates)
        XCTAssertTrue(CommandHelp.text(for:["keep-awake"]).contains("execution: app"))
    }
    func testMalformedOrMisplacedArgumentsAreRejectedBeforeDelivery() {
        for values in [["start","--mode","unknown"],["start","--seconds","0"],["start","--seconds","nan"],["start","--seconds","604801"],
                       ["start","--duration","manual","--seconds","30"],["start","--duration","oneHour"],
                       ["status","--mode","tasks"],["stop","--seconds","1"],["start","extra"],["start","--no-heat-guard"],["start","--csv"]] {
            XCTAssertThrowsError(try operation(values), values.joined(separator:" "))
        }
        XCTAssertThrowsError(try CommandContract.validate(Args(["awake","on","--mode","tasks"])))
        XCTAssertTrue(CommandHelp.text(for:["awake"]).contains("execution: helper"))
    }
}
