import XCTest
import ThermoKit
@testable import thermo

final class HelperStatusTests: XCTestCase {
    private func statusRows(_ text: String) throws -> [[String: String]] {
        let lines = text.split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
        let header = try XCTUnwrap(lines.first)
        return try lines.dropFirst().map { row in
            XCTAssertEqual(row.count, header.count)
            guard row.count == header.count else { throw NSError(domain: "CSV fixture", code: 1) }
            return Dictionary(uniqueKeysWithValues: zip(header, row))
        }
    }
    func testInventoryLossRetainsEveryPolicyAndLastObservationWithoutInventingLiveReadings() throws {
        let state = FanControlState(policies: [0: .fixed(rpm: 3000)], observations: [
            0: .init(mode: .manual, target: 3000, checkedAt: Date(timeIntervalSince1970: 1000)),
            1: .init(mode: .automatic, checkedAt: Date(timeIntervalSince1970: 1001))])
        let rows = try statusRows(Export.fanStatusCSV([], policies: state.policies, helperNote: nil, controlState: state, fansAvailable: false))
        XCTAssertEqual(rows.map { $0["id"] }, ["0", "1"])
        let desired = try XCTUnwrap(rows.first { $0["id"] == "0" }), observedOnly = try XCTUnwrap(rows.first { $0["id"] == "1" })
        XCTAssertEqual(desired["policy"], "fixed 3000 rpm")
        XCTAssertEqual(desired["verified_target_rpm"], "3000.000")
        XCTAssertEqual(observedOnly["last_observed_mode"], "automatic")
        for row in rows {
            XCTAssertEqual(row["rpm"], ""); XCTAssertEqual(row["target_rpm"], "")
            XCTAssertEqual(row["manual"], "unknown"); XCTAssertEqual(row["in_current_inventory"], "false")
            XCTAssertEqual(row["fans_available"], "false"); XCTAssertEqual(row["policies_available"], "true")
        }
        let terminal = Renderer(style: Style(enabled: false), showAll: false)
            .requestedFanPolicies([], policies: state.policies, controlState: state, available: true).joined(separator: "\n")
        XCTAssertTrue(terminal.contains("0 (no current reading)")); XCTAssertTrue(terminal.contains("fixed 3000 rpm"))
        XCTAssertTrue(terminal.contains("1 (no current reading)")); XCTAssertTrue(terminal.contains("last register check: automatic"))
    }
    func testPartialInventoryDoesNotDuplicateRecoveredFansOrDropMissingControls() throws {
        let fan = FanReading(id: 2, name: "Fixture", rpm: 2400, min: nil, max: nil, target: nil, manual: nil)
        let state = FanControlState(policies: [0: .fixed(rpm: .infinity), 2: .auto], observations: [2: .init(mode: .automatic)])
        let rows = try statusRows(Export.fanStatusCSV([fan], policies: state.policies, helperNote: nil, controlState: state))
        XCTAssertEqual(rows.map { $0["id"] }, ["0", "2"])
        let missing = try XCTUnwrap(rows.first { $0["id"] == "0" }), measured = try XCTUnwrap(rows.first { $0["id"] == "2" })
        XCTAssertEqual(missing["in_current_inventory"], "false"); XCTAssertEqual(missing["rpm"], "")
        XCTAssertEqual(measured["in_current_inventory"], "true"); XCTAssertEqual(measured["rpm"], "2400.000")
        XCTAssertEqual(missing["fans_available"], "true")
    }
    func testFanlessMetadataRowAndFailedHelperDoNotClaimLiveOrKnownPolicies() throws {
        let empty = try statusRows(Export.fanStatusCSV([], policies: [:], helperNote: nil))
        XCTAssertEqual(empty.count, 1); XCTAssertEqual(empty[0]["id"], "")
        XCTAssertEqual(empty[0]["in_current_inventory"], "false"); XCTAssertEqual(empty[0]["fans_available"], "true")
        let failed = try statusRows(Export.fanStatusCSV([], policies: [0: .fixed(rpm: 3000)], helperNote: "fixture unavailable", fansAvailable: false))
        XCTAssertEqual(failed.count, 1); XCTAssertEqual(failed[0]["id"], "0")
        XCTAssertEqual(failed[0]["policy"], "unknown"); XCTAssertEqual(failed[0]["policies_available"], "false")
        XCTAssertEqual(failed[0]["in_current_inventory"], "false")
    }
    func testTemperatureLossSuspensionIsReportedWithoutClaimingOverheating() {
        let state = FanControlState(policies: [:], suspended: true, suspensionReason: .temperatureUnavailable)
        XCTAssertTrue(Renderer.controlText(state, fan: 0).contains("temperature telemetry loss"))
        let csv = Export.fanStatusCSV([], policies: [:], helperNote: nil, controlState: state)
        XCTAssertTrue(csv.contains("policies_suspended,suspension_reason,control_failure"))
        XCTAssertTrue(csv.contains("true,temperatureUnavailable,"))
    }
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
    func testFailedInventoryIsPreservedAcrossFilteringTerminalAndCSV() throws {
        let snapshot = Snapshot(temperatures: [], fans: [], power: [], voltages: [], currents: [], battery: nil,
                                fansAvailable: false)
        let app = App(args: try Args([]))
        XCTAssertEqual(app.filtered(snapshot).fansAvailable, false)
        let terminal = Renderer(style: Style(enabled: false), showAll: false).fans(snapshot).joined(separator: "\n")
        XCTAssertTrue(terminal.contains("unavailable")); XCTAssertFalse(terminal.contains("no fans"))
        let csv = Export.fanStatusCSV([], policies: [:], helperNote: nil, fansAvailable: false)
        let lines = csv.components(separatedBy: "\n").map { $0.components(separatedBy: ",") }
        let column = try XCTUnwrap(lines[0].firstIndex(of: "fans_available"))
        XCTAssertEqual(lines[1][column], "false")
        XCTAssertTrue(Export.csv(snapshot, all: false).contains("fan_availability,FNum,Fan inventory,Fan,false"))
    }

    func testWatchCSVColumnsRemainStableWhenUnknownFanDiscoveryRecovers() throws {
        let unknown = Snapshot(temperatures: [], fans: [], power: [], voltages: [], currents: [], battery: nil,
                               fansAvailable: false)
        let recovered = Snapshot(temperatures: [], fans: [.init(id: 0, name: "Fan", rpm: 2500, min: nil,
                                  max: nil, target: nil, manual: nil)], power: [], voltages: [], currents: [], battery: nil)
        let ids = Export.streamFanIDs(unknown)
        let header = Export.csvStreamHeader(unknown, fanIDs: ids).components(separatedBy: ",")
        let first = Export.csvStreamRow(unknown, fanIDs: ids).components(separatedBy: ",")
        let second = Export.csvStreamRow(recovered, fanIDs: ids).components(separatedBy: ",")
        XCTAssertEqual(header.count, first.count); XCTAssertEqual(header.count, second.count)
        XCTAssertEqual(first[try XCTUnwrap(header.firstIndex(of: "fan0_rpm"))], "")
        XCTAssertEqual(second[try XCTUnwrap(header.firstIndex(of: "fan0_rpm"))], "2500")
        XCTAssertEqual(first[try XCTUnwrap(header.firstIndex(of: "fans_available"))], "false")
        XCTAssertEqual(second[try XCTUnwrap(header.firstIndex(of: "fan_count"))], "1")
    }

}
