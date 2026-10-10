import XCTest
import ThermoKit
@testable import thermo

final class HelperStatusTests: XCTestCase {
    func testUnavailablePoliciesAreNotReportedAsAuto() {
        XCTAssertEqual(Renderer.policyText(nil, available: false), "unknown")
        XCTAssertEqual(Renderer.policyText(.fixed(rpm: 3500), available: false), "unknown")
        XCTAssertEqual(Renderer.policyText(nil, available: true), "auto")
    }

    func testConnectedBackgroundHelperCountsAsInstalled() {
        let fields = App.helperStatusFields(legacyInstalled: false, version: "fixture-version")
        XCTAssertEqual(fields["installed"], "true")
        XCTAssertEqual(fields["running"], "true")
        XCTAssertEqual(fields["installationSource"], "connected")
        XCTAssertTrue(Export.helperStatusCSV(fields).contains("true,true,fixture-version,connected"))
    }

    func testAbsentLegacyFilesAndConnectionLeaveBackgroundRegistrationUnknown() {
        let fields = App.helperStatusFields(legacyInstalled: false, version: nil)
        XCTAssertEqual(fields["installationSource"], "unknown")
        XCTAssertEqual(fields["running"], "false")
    }

    func testFanCSVRetainsUnknownPolicyAndEscapesName() throws {
        let fan = try JSONDecoder().decode(FanReading.self, from: Data("""
        {"id":0,"name":"Left, fan","rpm":3200,"min":2000,"max":6000,"manual":true}
        """.utf8))
        let csv = Export.fanStatusCSV([fan], policies: [:], helperNote: "fixture failure")
        XCTAssertTrue(csv.contains("\"Left, fan\""))
        XCTAssertTrue(csv.contains(",true,unknown,false,fixture failure"))
    }

    func testFanlessCSVStillReportsHelperState() {
        XCTAssertTrue(Export.fanStatusCSV([], policies: [:], helperNote: "fixture failure").hasSuffix(",false,fixture failure"))
    }
}
