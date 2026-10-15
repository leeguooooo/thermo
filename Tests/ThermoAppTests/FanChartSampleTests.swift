import XCTest
@testable import ThermoApp

final class FanChartSampleTests: XCTestCase {
    func testMissingSpeedSplitsOnlyItsOwnSeriesAndNeverShiftsTheOtherFan() {
        func point(_ time: Double, _ fans: [Double?]) -> HistoryPoint {
            .init(time: Date(timeIntervalSince1970: time), cpu: nil, gpu: nil, fans: fans, power: nil)
        }
        let samples = FanChartSample.samples([point(0, [2000, 3000]), point(1, [nil, 3100]), point(2, [2200, 3200])])
        let first = samples.filter { $0.fan == 0 }, second = samples.filter { $0.fan == 1 }
        XCTAssertEqual(first.map(\.rpm), [2000, 2200])
        XCTAssertNotEqual(first[0].segment, first[1].segment)
        XCTAssertEqual(second.map(\.rpm), [3000, 3100, 3200])
        XCTAssertEqual(Set(second.map(\.segment)).count, 1)
    }

    func testStoppedFanIsPlottedButAbsentOrInvalidSamplesAreNot() {
        let samples = FanChartSample.samples([
            .init(time: Date(), cpu: nil, gpu: nil, fans: [0, .nan, -1], power: nil),
            .init(time: Date().addingTimeInterval(1), cpu: nil, gpu: nil, fans: [], power: nil)])
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.rpm, 0)
    }
}
