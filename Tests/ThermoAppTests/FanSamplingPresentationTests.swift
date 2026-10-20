import XCTest
import ThermoKit
@testable import ThermoApp

final class FanSamplingPresentationTests: XCTestCase {
    func testMissingReadingsKeepSavedPendingAndObservationOnlyControlsSeparateFromLiveFans() {
        let state = FanControlState(policies: [0: .fixed(rpm: 3000)], observations: [1: .init(mode: .automatic)])
        let policies = state.policies, pending: [Int: FanPolicy] = [2: .curve(.quiet)]
        XCTAssertEqual(FanControlPresentation.missingFanIDs(readings: nil, policies: policies, pending: pending, state: state), [0, 1, 2])
        let recovered = FanReading(id: 0, name: "Fixture", rpm: 2500, min: nil, max: nil, target: nil, manual: nil)
        XCTAssertEqual(FanControlPresentation.missingFanIDs(readings: [recovered], policies: policies, pending: pending, state: state), [1, 2])
        XCTAssertEqual(FanControlPresentation.missingFanIDs(readings: [], policies: [:], pending: [:], state: nil), [])
    }
    func testKnownControlFailureSurvivesUnsupportedHardwareVerification() {
        let state = FanControlState(policies: [0: .auto], failure: "fixture control failure", observationsSupported: false)
        XCTAssertTrue(FanControlPresentation.observation(state, fan: 0).contains("fixture control failure"))
    }
    func testUnrequestedFansAreUnknownAndAnActualEmptyFanSampleIsFanless() {
        let monitor = Monitor(startMonitoring: false, helperInteraction: false)
        let empty = Snapshot(temperatures: [], fans: [], power: [], voltages: [], currents: [], battery: nil, fansAvailable: true)
        XCTAssertNil(monitor.sampledFans)
        monitor.publishSnapshot(empty, parts: .temperatures)
        XCTAssertNil(monitor.sampledFans)
        monitor.publishSnapshot(empty, parts: .everything)
        XCTAssertEqual(monitor.sampledFans?.count, 0)
        let fan = FanReading(id: 0, name: "Fan", rpm: 2000, min: nil, max: nil, target: nil, manual: nil)
        let measured = Snapshot(temperatures: [], fans: [fan], power: [], voltages: [], currents: [], battery: nil)
        monitor.publishSnapshot(measured, parts: .fans)
        XCTAssertEqual(monitor.sampledFans?.first?.rpm, 2000)
        monitor.publishSnapshot(empty, parts: .temperatures)
        XCTAssertNil(monitor.sampledFans)
    }
    func testFailedFanDiscoveryStaysUnavailableUntilAValidInventoryArrives() {
        let monitor = Monitor(startMonitoring: false, helperInteraction: false)
        let failed = Snapshot(temperatures: [], fans: [], power: [], voltages: [], currents: [], battery: nil,
                              fansAvailable: false)
        monitor.publishSnapshot(failed, parts: .everything)
        XCTAssertNil(monitor.sampledFans)
        XCTAssertTrue(monitor.fanReadingsUnavailable)
        let zero = Snapshot(temperatures: [], fans: [], power: [], voltages: [], currents: [], battery: nil, fansAvailable: true)
        monitor.publishSnapshot(zero, parts: .everything)
        XCTAssertEqual(monitor.sampledFans?.count, 0)
        XCTAssertFalse(monitor.fanReadingsUnavailable)
        monitor.publishSnapshot(failed, parts: .temperatures)
        XCTAssertNil(monitor.sampledFans)
        XCTAssertFalse(monitor.fanReadingsUnavailable)
    }

}
