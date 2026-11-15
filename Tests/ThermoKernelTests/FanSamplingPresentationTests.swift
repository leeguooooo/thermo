import XCTest
import ThermoKit
@testable import ThermoKernel

@MainActor final class FanSamplingPresentationTests: XCTestCase {


    func testUnrequestedFansAreUnknownAndAnActualEmptyFanSampleIsFanless() {
        let monitor = CoreTelemetry(samplingAllowed:{false})
        let empty = Snapshot(temperatures: [], fans: [], power: [], voltages: [], currents: [], battery: nil, fansAvailable: true)
        XCTAssertNil(monitor.latest.sampledFans)
        monitor.publishSnapshot(empty, parts: .temperatures)
        XCTAssertNil(monitor.latest.sampledFans)
        monitor.publishSnapshot(empty, parts: .everything)
        XCTAssertEqual(monitor.latest.sampledFans?.count, 0)
        let fan = FanReading(id: 0, name: "Fan", rpm: 2000, min: nil, max: nil, target: nil, manual: nil)
        let measured = Snapshot(temperatures: [], fans: [fan], power: [], voltages: [], currents: [], battery: nil)
        monitor.publishSnapshot(measured, parts: .fans)
        XCTAssertEqual(monitor.latest.sampledFans?.first?.rpm, 2000)
        monitor.publishSnapshot(empty, parts: .temperatures)
        XCTAssertNil(monitor.latest.sampledFans)
    }
    func testFailedFanDiscoveryStaysUnavailableUntilAValidInventoryArrives() {
        let monitor = CoreTelemetry(samplingAllowed:{false})
        let failed = Snapshot(temperatures: [], fans: [], power: [], voltages: [], currents: [], battery: nil,
                              fansAvailable: false)
        monitor.publishSnapshot(failed, parts: .everything)
        XCTAssertNil(monitor.latest.sampledFans)
        XCTAssertTrue(monitor.latest.fanReadingsUnavailable)
        let zero = Snapshot(temperatures: [], fans: [], power: [], voltages: [], currents: [], battery: nil, fansAvailable: true)
        monitor.publishSnapshot(zero, parts: .everything)
        XCTAssertEqual(monitor.latest.sampledFans?.count, 0)
        XCTAssertFalse(monitor.latest.fanReadingsUnavailable)
        monitor.publishSnapshot(failed, parts: .temperatures)
        XCTAssertNil(monitor.latest.sampledFans)
        XCTAssertFalse(monitor.latest.fanReadingsUnavailable)
    }

    func testOnlyConsecutiveNewFanSamplesConfirmAStoppedFan() {
        let core=CoreTelemetry(samplingAllowed:{false})
        let idle=FanReading(id:0,name:"Fan",rpm:0,min:2317,max:6550,target:nil,manual:false)
        func frame(_ tick:Double,_ fan:FanReading)->Snapshot {
            .init(timestamp:Date(timeIntervalSince1970:tick),temperatures:[],fans:[fan],power:[],voltages:[],currents:[],battery:nil)
        }
        core.publishSnapshot(frame(1,idle),parts:.fans);core.publishSnapshot(frame(2,idle),parts:.fans)
        core.publishSnapshot(frame(2,idle),parts:.fans)
        XCTAssertTrue(core.latest.stoppedFans.isEmpty,"Replaying a visible value is not a new SMC sample")
        core.publishSnapshot(frame(3,idle),parts:.fans);XCTAssertEqual(core.latest.stoppedFans,[0])
        let spinning=FanReading(id:0,name:"Fan",rpm:2400,min:2317,max:6550,target:nil,manual:false)
        core.publishSnapshot(frame(4,spinning),parts:.fans);XCTAssertTrue(core.latest.stoppedFans.isEmpty)
    }

}
