import XCTest
@testable import ThermoKit

final class FanMissingReadingTests: XCTestCase {
    func testMissingSpeedPreservesBothFanIdentitiesAndOtherReadings() {
        let fans = [FanDescriptor(index: 0, name: "Left", hasModeKey: true), .init(index: 1, name: "Right", hasModeKey: true)]
        let values: [FourCC: Double] = ["F0Md": 1, "F0Tg": 3000, "F1Md": 0, "F1Ac": 2000]
        let readings = FanSampler.read(fans, hasForceKey: false, limits: [0: (1200, 6000), 1: (1200, 6000)]) {
            guard let value = values[$0] else { throw SMCError.keyNotFound($0) }; return value
        }
        XCTAssertEqual(readings.map(\.id), [0, 1])
        XCTAssertEqual(readings.map(\.name), ["Left", "Right"])
        XCTAssertNil(readings[0].rpm)
        XCTAssertNil(readings[0].load)
        XCTAssertEqual(readings[0].target, 3000)
        XCTAssertEqual(readings[1].rpm, 2000)
    }

    func testInvalidNumbersAndRangesNeverBecomeZeroOrUsableControlLimits() {
        for value in [Double.nan, Double.infinity, -1] {
            let fan = FanReading(id: 0, name: "Fixture", rpm: value, min: value, max: value, target: value, manual: nil)
            XCTAssertNil(fan.rpm); XCTAssertNil(fan.min); XCTAssertNil(fan.max); XCTAssertNil(fan.target)
            XCTAssertNil(fan.load); XCTAssertNil(fan.validRange)
        }
        let reversed = FanReading(id: 0, name: "Fixture", rpm: 0, min: 6000, max: 1200, target: 0, manual: false)
        XCTAssertEqual(reversed.rpm, 0, "a genuinely stopped fan remains a known zero")
        XCTAssertNil(reversed.validRange)
        XCTAssertNil(reversed.min); XCTAssertNil(reversed.max)
        let partial = FanReading(id: 0, name: "Fixture", rpm: 2000, min: 1200, max: nil, target: nil, manual: false)
        XCTAssertEqual(partial.min, 1200); XCTAssertNil(partial.validRange); XCTAssertNil(partial.load)
    }

    func testUnknownNumbersRoundTripAsNullAndOldNumericSnapshotsRemainReadable() throws {
        let fan = FanReading(id: 0, name: "Fixture", rpm: nil, min: nil, max: nil, target: nil, manual: nil)
        let data = try JSONEncoder().encode(fan)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["rpm", "min", "max"] { XCTAssertTrue(object[key] is NSNull) }
        XCTAssertEqual(try JSONDecoder().decode(FanReading.self, from: data), fan)
        let old = Data("{\"id\":0,\"name\":\"Fixture\",\"rpm\":2000,\"min\":1200,\"max\":6000,\"manual\":false}".utf8)
        XCTAssertEqual(try JSONDecoder().decode(FanReading.self, from: old).rpm, 2000)
    }

    func testMissingLimitsRequestAutoForFixedAndCurvePoliciesIncludingWhileSuspended() {
        let fan = FanReading(id: 0, name: "Fixture", rpm: nil, min: nil, max: nil, target: nil, manual: true)
        let snapshot = Snapshot(temperatures: [], fans: [fan], power: [], voltages: [], currents: [], battery: nil)
        for policy: FanPolicy in [.fixed(rpm: 2500), .fixed(rpm: .infinity), .curve(.quiet)] {
            var engine = FanPolicyEngine()
            engine.set(policy, for: 0)
            XCTAssertEqual(engine.tick(snapshot), [.auto(fan: 0)])
            XCTAssertEqual(engine.policies[0], policy, "desired policy can resume after valid limits return")
        }
        var suspended = FanPolicyEngine()
        suspended.set(.fixed(rpm: 2500), for: 0)
        let known = FanReading(id: 0, name: "Fixture", rpm: 2500, min: 1200, max: 6000, target: 2500, manual: true)
        let hot = Snapshot(temperatures: [.init(key: "TC0P", name: "CPU", group: .cpu, value: 97)],
                           fans: [known], power: [], voltages: [], currents: [], battery: nil)
        _ = suspended.tick(hot); _ = suspended.tick(hot)
        XCTAssertTrue(suspended.suspended)
        XCTAssertEqual(suspended.tick(snapshot), [.auto(fan: 0)])
        XCTAssertTrue(suspended.suspended, "missing limits must not reset thermal protection")
    }
}
