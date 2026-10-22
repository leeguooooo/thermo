import XCTest
import ThermoKit
@testable import ThermoApp

final class SamplingPlanTests: XCTestCase {
    func testVisibleSurfacesKeepSidebarReadingsWithoutUnrelatedHardwareWork() {
        let compact = SamplingPlan.make(visible: true, includeUnnamed: false, metrics: [.cpu], alerts: false, surface: .compact)
        XCTAssertEqual(compact.parts, [.temperatures, .fans])
        XCTAssertNil(compact.groups, "keep the hottest known temperature truthful in the sidebar")
        let power = SamplingPlan.make(visible: true, includeUnnamed: false, metrics: [.power], alerts: false, surface: .compact)
        XCTAssertTrue(power.parts.contains(.power), "selected menu metrics still run on compact pages")
        let overview = SamplingPlan.make(visible: true, includeUnnamed: false, metrics: [], alerts: false, surface: .overview)
        XCTAssertEqual(overview.parts, [.temperatures, .fans, .power, .battery])
        XCTAssertFalse(overview.parts.contains(.electrical))
        let sensors = SamplingPlan.make(visible: true, includeUnnamed: true, metrics: [], alerts: false, surface: .sensors)
        XCTAssertEqual(sensors.parts, .everything)
        XCTAssertEqual(sensors.scope, .all)
    }

    func testSelectedMetricsUseUnionRegardlessOfPrimaryOrder() {
        let selections: [Set<MenuMetric>] = [[.cpu, .power], [.fan, .hottest], [.fan, .power]]
        for metrics in selections {
            let plan = SamplingPlan.make(visible: false, includeUnnamed: false, metrics: metrics, alerts: false)
            XCTAssertEqual(plan.scope, .known); XCTAssertNil(plan.groups)
            XCTAssertEqual(plan.parts.contains(.power), metrics.contains(.power))
            XCTAssertEqual(plan.parts.contains(.fans), metrics.contains(.fan))
            XCTAssertEqual(plan.parts.contains(.temperatures), !metrics.isDisjoint(with: [.cpu, .hottest]))
        }
    }

    func testLiveAndIconSelectionsDoNotReadSensorsUnlessVisibleOrAlerting() {
        let selections: [Set<MenuMetric>] = [[], [.cpuUsage, .memory], [.download, .upload]]
        for metrics in selections {
            XCTAssertTrue(SamplingPlan.make(visible: false, includeUnnamed: false, metrics: metrics, alerts: false).parts.isEmpty)
            XCTAssertTrue(SamplingPlan.make(visible: false, includeUnnamed: false, metrics: metrics, alerts: true).parts.contains(.temperatures))
            XCTAssertEqual(SamplingPlan.make(visible: true, includeUnnamed: false, metrics: metrics, alerts: false).parts, .everything)
        }
    }

    func testSensorSearchMatchesKeysAndDisplayedElectricalCategories() {
        let reading = Reading(key: "PC0R", name: "CPU Package Power", group: .cpu, value: 42)
        XCTAssertTrue(SensorSearch.matches(reading, query: " pc0r "))
        XCTAssertTrue(SensorSearch.matches(reading, query: "功率", category: "功率"))
        XCTAssertFalse(SensorSearch.matches(reading, query: "功率"))
        XCTAssertFalse(SensorSearch.matches(reading, query: "not a sensor", category: "功率"))
    }

    func testDefaultBackgroundCPUPlanStaysEssential() {
        let plan = SamplingPlan.make(visible: false, includeUnnamed: true, metric: .cpu, alerts: false)
        XCTAssertEqual(plan.scope, .essential)
        XCTAssertEqual(plan.groups, [.cpu, .gpu])
        XCTAssertFalse(plan.parts.contains(.power))
    }

    func testHottestAndAlertPlansCoverEveryCuratedGroupInBackground() {
        for (metric, alerts) in [(TitleMetric.hottest, false), (.cpu, true)] {
            let plan = SamplingPlan.make(visible: false, includeUnnamed: false, metric: metric, alerts: alerts)
            XCTAssertEqual(plan.scope, .known)
            XCTAssertNil(plan.groups)
        }
    }

    func testPowerMetricKeepsItsPowerReadings() {
        let plan = SamplingPlan.make(visible: false, includeUnnamed: false, metric: .power, alerts: true)
        XCTAssertTrue(plan.parts.contains(.power))
        XCTAssertEqual(plan.scope, .known)
    }

    func testUnnamedScopeIsOnlyUsedWhenVisible() {
        let plan = SamplingPlan.make(visible: true, includeUnnamed: true, metric: .cpu, alerts: false)
        XCTAssertEqual(plan.scope, .all)
        XCTAssertNil(plan.groups)
        XCTAssertEqual(plan.parts, .everything)
    }
}
