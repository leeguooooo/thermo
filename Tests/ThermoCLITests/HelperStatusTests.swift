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
        XCTAssertTrue(csv.contains(",true,unknown,unavailable,"))
        XCTAssertTrue(csv.hasSuffix(",false,fixture failure"))
    }

    func testFanlessCSVStillReportsHelperState() {
        XCTAssertTrue(Export.fanStatusCSV([], policies: [:], helperNote: "fixture failure").hasSuffix(",false,fixture failure"))
    }

    func testStatusSeparatesAcceptedPolicyFromPendingAndVerifiedRegisters() throws {
        let fan = try JSONDecoder().decode(FanReading.self, from: Data("""
        {"id":0,"name":"Fixture","rpm":1800,"min":1200,"max":6000,"manual":false}
        """.utf8))
        var state = FanControlState(policies: [0: .fixed(rpm: 3000)])
        var csv = Export.fanStatusCSV([fan], policies: state.policies, helperNote: nil, controlState: state)
        XCTAssertTrue(csv.contains("verification_state,last_observed_mode,verified_target_rpm,checked_at"))
        XCTAssertTrue(csv.contains("fixed 3000 rpm,pending,"))
        XCTAssertTrue(Renderer.controlText(state, fan: 0).contains("pending"))
        state.observations[0] = .init(mode: .manual, target: 3000, checkedAt: Date(timeIntervalSince1970: 1000))
        csv = Export.fanStatusCSV([fan], policies: state.policies, helperNote: nil, controlState: state)
        XCTAssertTrue(csv.contains("checked,manual,3000.000,1970-01-01T00:16:40Z"))
        XCTAssertTrue(Renderer.controlText(state, fan: 0).contains("last register check"))
        state.failure = "mode lost, retry required"
        csv = Export.fanStatusCSV([], policies: state.policies, helperNote: nil, controlState: state)
        XCTAssertTrue(csv.contains("failed,"))
        XCTAssertTrue(csv.contains("\"mode lost, retry required\""))
    }

    func testUnknownSampledModeStaysUnknownInTerminalCSVAndPulse() throws {
        let fan = try JSONDecoder().decode(FanReading.self, from: Data("""
        {"id":0,"name":"Fixture","rpm":1800,"min":1200,"max":6000,"manual":null}
        """.utf8))
        let csv = Export.fanStatusCSV([fan], policies: [:], helperNote: nil)
        XCTAssertTrue(csv.contains(",unknown,auto,unavailable,"), "known desired auto is separate from unknown sampled mode")
        let snapshot = Snapshot(temperatures: [], fans: [fan], power: [], voltages: [], currents: [], battery: nil)
        let terminal = Renderer(style: Style(enabled: false), showAll: false).fans(snapshot).joined(separator: "\n")
        XCTAssertTrue(terminal.contains("unknown"))
        XCTAssertFalse(terminal.contains("auto"))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PulseCommand.Report.Fan(fan))) as? [String: Any]
        XCTAssertEqual(json?["controlMode"] as? String, "unknown")
        XCTAssertNil(json?["manual"] as? Bool)
    }

    func testMissingSpeedAndRangeAreRetainedWithoutZeroOrFanlessClaims() throws {
        let fan = FanReading(id: 0, name: "Fixture", rpm: nil, min: nil, max: nil, target: nil, manual: nil)
        let snapshot = Snapshot(temperatures: [], fans: [fan], power: [], voltages: [], currents: [], battery: nil)
        let text = Renderer(style: Style(enabled: false), showAll: false).fans(snapshot).joined(separator: "\n")
        XCTAssertTrue(text.contains("Fixture")); XCTAssertTrue(text.contains("unknown rpm"))
        XCTAssertFalse(text.contains("no fans")); XCTAssertFalse(text.contains("0 rpm"))
        XCTAssertTrue(Export.csv(snapshot, all: true).contains("fan,F0Ac,Fixture,Fan,\n") || Export.csv(snapshot, all: true).hasSuffix("fan,F0Ac,Fixture,Fan,"))
        XCTAssertTrue(Export.fanStatusCSV([fan], policies: [:], helperNote: nil).contains("0,Fixture,,,,,unknown"))
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        let fans = try XCTUnwrap(object?["fans"] as? [[String: Any]])
        XCTAssertEqual(fans.count, 1); XCTAssertTrue(fans[0]["rpm"] is NSNull)
    }
}
