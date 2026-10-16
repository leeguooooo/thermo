import XCTest
@testable import thermo

final class AWDLRequestTests: XCTestCase {
    func request(_ arguments: [String]) throws -> AWDLRequest {
        let args=try Args(["awdl"]+arguments)
        return try AWDLRequest(Array(args.positionals.dropFirst()),args:args)
    }
    func testReadOnlyProbeAndPreviewAreExplicitModes() throws {
        XCTAssertEqual(try request([]),.status(probe:false))
        XCTAssertEqual(try request(["status","--probe","--json"]),.status(probe:true))
        XCTAssertEqual(try request(["on","--seconds","60","--dry-run"]),.on(seconds:60,preview:true))
        XCTAssertEqual(try request(["on"]),.on(seconds:300,preview:false))
        XCTAssertEqual(try request(["recover"]),.recover)
    }
    func testMalformedOrMisplacedControlsFailBeforeHelperUse() {
        for args in [["on","--seconds","1"],["on","--seconds","3601"],["on","--seconds","nan"],["on","--probe"],
                     ["status","--seconds","60"],["recover","--dry-run"],["recover","--probe"],["on","extra"],["off"]] {
            XCTAssertThrowsError(try request(args),args.joined(separator:" "))
        }
    }
}
