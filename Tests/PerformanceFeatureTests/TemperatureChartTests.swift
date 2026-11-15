import Foundation
import XCTest
import SystemServicesAPI
@testable import PerformanceFeature

final class TemperatureChartTests:XCTestCase{
    func testChartIncludesHotAppleSiliconReadings() {
        let chart = TemperatureChart(history: [HistoryPoint(time: Date(), cpu: 115, gpu: 15, fans: [], power: nil)])
        XCTAssertLessThanOrEqual(chart.domain.lowerBound, chart.temperature(10))
        XCTAssertGreaterThanOrEqual(chart.domain.upperBound, chart.temperature(120))
    }
    func testChartIgnoresNonFiniteReadings() {
        let chart = TemperatureChart(history: [HistoryPoint(time: Date(), cpu: .nan, gpu: .infinity, fans: [], power: nil)])
        XCTAssertTrue(chart.domain.lowerBound.isFinite)
        XCTAssertTrue(chart.domain.upperBound.isFinite)
        XCTAssertLessThan(chart.domain.lowerBound, chart.domain.upperBound)
    }
}
