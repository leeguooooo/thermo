import XCTest
@testable import ThermoKit

final class FanModeReadingTests: XCTestCase {
    func testKnownModesAndMissingOrUnexpectedModeReadings() {
        for mode in [0.0, 3] {
            XCTAssertEqual(FanModeReader.manual(mode: mode, hasModeKey: true, forceBits: nil, hasForceKey: false, fan: 0), false)
        }
        XCTAssertEqual(FanModeReader.manual(mode: 1, hasModeKey: true, forceBits: nil, hasForceKey: false, fan: 0), true)
        for mode in [nil, Double.nan, Double.infinity, -1, 2, 1.5] as [Double?] {
            XCTAssertNil(FanModeReader.manual(mode: mode, hasModeKey: true, forceBits: nil, hasForceKey: false, fan: 0))
        }
        XCTAssertNil(FanModeReader.manual(mode: nil, hasModeKey: false, forceBits: nil, hasForceKey: false, fan: 0))
    }

    func testAutomaticNeedsAllApplicableFlagsButAnyKnownManualFlagIsPreserved() {
        XCTAssertNil(FanModeReader.manual(mode: 0, hasModeKey: true, forceBits: nil, hasForceKey: true, fan: 0))
        XCTAssertNil(FanModeReader.manual(mode: nil, hasModeKey: true, forceBits: 0, hasForceKey: true, fan: 0))
        XCTAssertEqual(FanModeReader.manual(mode: 0, hasModeKey: true, forceBits: 0, hasForceKey: true, fan: 0), false)
        XCTAssertEqual(FanModeReader.manual(mode: nil, hasModeKey: true, forceBits: 1, hasForceKey: true, fan: 0), true)
        XCTAssertEqual(FanModeReader.manual(mode: 1, hasModeKey: true, forceBits: nil, hasForceKey: true, fan: 0), true)
    }

    func testForceReadingsRejectInvalidNumbersAndBitIndexesWithoutConversionTraps() {
        for bits in [nil, Double.nan, Double.infinity, -1, 65536, 1.5] as [Double?] {
            XCTAssertNil(FanModeReader.manual(mode: nil, hasModeKey: false, forceBits: bits, hasForceKey: true, fan: 0))
        }
        for id in [-1, 16, Int.max, Int.min] {
            XCTAssertNil(FanModeReader.manual(mode: nil, hasModeKey: false, forceBits: 1, hasForceKey: true, fan: id))
        }
        XCTAssertEqual(FanModeReader.manual(mode: nil, hasModeKey: false, forceBits: 32768, hasForceKey: true, fan: 15), true)
        XCTAssertEqual(FanModeReader.manual(mode: nil, hasModeKey: false, forceBits: 32768, hasForceKey: true, fan: 0), false)
    }

    func testUnknownModeRoundTripsAsNullAndOldBooleanConsumersCannotReadItAsAuto() throws {
        let reading = FanReading(id: 0, name: "Fixture", rpm: 1800, min: 1200, max: 6000, target: nil, manual: nil)
        let data = try JSONEncoder().encode(reading)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(object["manual"] is NSNull)
        let decoded = try JSONDecoder().decode(FanReading.self, from: data)
        XCTAssertNil(decoded.manual)
        XCTAssertEqual(decoded.controlMode, "unknown")
        struct OldConsumer: Decodable { let manual: Bool }
        XCTAssertThrowsError(try JSONDecoder().decode(OldConsumer.self, from: data))
    }

    func testExistingBooleanSnapshotsRemainReadableAndMissingModeIsUnknown() throws {
        for (field, expected) in [("true", true), ("false", false)] {
            let data = Data("{\"id\":0,\"name\":\"Fixture\",\"rpm\":1800,\"min\":1200,\"max\":6000,\"manual\":\(field)}".utf8)
            XCTAssertEqual(try JSONDecoder().decode(FanReading.self, from: data).manual, expected)
        }
        let missing = Data("{\"id\":0,\"name\":\"Fixture\",\"rpm\":1800,\"min\":1200,\"max\":6000}".utf8)
        XCTAssertNil(try JSONDecoder().decode(FanReading.self, from: missing).manual)
    }
}
