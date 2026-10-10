import XCTest
import SwiftUI
import AppKit
import ThermoKit
import ThermoL10n
@testable import CleanKit
@testable import ThermoApp

final class PresentationTests: XCTestCase {
    @MainActor func testNativeMenusRouteTextAndWindowShortcuts() {
        _ = NSApplication.shared
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous }
        NSApp.mainMenu = NSMenu()
        installStandardMenus()
        let count = NSApp.mainMenu?.items.count
        installStandardMenus()
        XCTAssertEqual(NSApp.mainMenu?.items.count, count)
        let items = NSApp.mainMenu?.items.flatMap { $0.submenu?.items ?? [] } ?? []
        XCTAssertEqual(items.first { $0.keyEquivalent == "a" }?.action, #selector(NSText.selectAll(_:)))
        XCTAssertEqual(items.first { $0.keyEquivalent == "c" }?.action, #selector(NSText.copy(_:)))
        XCTAssertEqual(items.first { $0.keyEquivalent == "w" }?.action, #selector(NSWindow.performClose(_:)))
    }

    @MainActor func testNativeNavigationMenusRelocalizeWithoutDuplicates() {
        _ = NSApplication.shared
        let previous = NSApp.mainMenu
        let previousWindows = NSApp.windowsMenu
        defer { NSApp.mainMenu = previous; NSApp.windowsMenu = previousWindows; L10n.override = nil }
        NSApp.mainMenu = NSMenu()
        L10n.override = .english
        installStandardMenus()
        let view = NSApp.mainMenu?.items.first { $0.identifier?.rawValue == "thermo.view" }
        XCTAssertEqual(view?.title, "View")
        let items = view?.submenu?.items ?? []
        XCTAssertEqual(items.map(\.keyEquivalent), ["1", "2", "3", "4", "5", "6", ","])
        XCTAssertEqual(items.first?.representedObject as? MainPage, .overview)
        XCTAssertEqual(items.last?.representedObject as? MainPage, .settings)
        L10n.override = .simplifiedChinese
        installStandardMenus()
        for id in ["thermo.edit", "thermo.view", "thermo.window"] {
            XCTAssertEqual(NSApp.mainMenu?.items.filter { $0.identifier?.rawValue == id }.count, 1)
        }
        let translated = NSApp.mainMenu?.items.first { $0.identifier?.rawValue == "thermo.view" }
        XCTAssertEqual(translated?.title, "显示")
        XCTAssertEqual(translated?.submenu?.items.first?.title, "概览")
    }

    @MainActor func testDiagnosticsCannotScanDuringBatchFix() {
        let scanner = AgentScanner()
        scanner.batch = AgentScanner.Batch(total: 2)
        XCTAssertTrue(scanner.busy)
        scanner.scan()
        XCTAssertFalse(scanner.scanning)
        scanner.batch?.finished = true
        XCTAssertFalse(scanner.busy)
    }

    @MainActor func testDiskRefreshRetainsPreviousLocationsAndReplacesUpdatedOnes() {
        let old = [SpaceOverview.Entry(id: "a", title: "A", bytes: 100, children: []),
                   SpaceOverview.Entry(id: "b", title: "B", bytes: 200, children: [])]
        let update = SpaceOverview.Entry(id: "a", title: "A", bytes: 300, children: [])
        let merged = SpaceOverviewModel.merging(old, updates: [update])
        XCTAssertEqual(merged.map(\.id), ["a", "b"])
        XCTAssertEqual(merged.map(\.bytes), [300, 200])
    }

    @MainActor func testWindowPlacementRecoversFromOffscreenSnapshotsAndDisconnectedDisplays() {
        let screen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertFalse(MainWindow.usableFrame(NSRect(x: -6000, y: -6000, width: 1100, height: 740), screens: [screen]))
        XCTAssertFalse(MainWindow.usableFrame(NSRect(x: 2500, y: 0, width: 1100, height: 740), screens: [screen]))
        XCTAssertTrue(MainWindow.usableFrame(NSRect(x: 100, y: 100, width: 1100, height: 740), screens: [screen]))
    }

    @MainActor func testLanguageSwitchDiscardsDiskTitlesFromPreviousLanguage() {
        L10n.override = .english
        defer { L10n.override = nil }
        var overview = SpaceOverview(capacity: 100, free: 25, purgeable: 0,
                                     entries: [.init(id: "apps", title: "Applications", bytes: 10, children: [])], duration: 1)
        overview.language = "en"
        let model = SpaceOverviewModel(cached: (overview, Date()))
        XCTAssertEqual(model.entries.count, 1)
        L10n.override = .simplifiedChinese
        model.discardIncompatibleResults()
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertNil(model.overview)
        XCTAssertNil(model.measuredAt)
    }

    func testEmptyPageArgumentDoesNotCrash() {
        XCTAssertNil(MainPage(argument: ""))
        XCTAssertNil(MainPage(argument: ":"))
        XCTAssertEqual(MainPage(argument: "sensors"), .sensors)
        XCTAssertEqual(MainPage(argument: "disk:overview"), .disk(.overview))
    }

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

    func testGaugeHandlesInvalidValuesAndEmptyPalette() {
        _ = RingGauge(value: .nan, text: "—").color
        _ = RingGauge(value: .infinity, text: "—").color
        _ = RingGauge(value: -1, text: "—").color
        _ = RingGauge(value: 2, text: "—", colors: []).color
    }

    func testMissingGaugeReadingsAreDifferentFromZero() {
        let missing = RingGauge(value: nil, text: "—")
        let invalid = RingGauge(value: .nan, text: "nan")
        let zero = RingGauge(value: 0, text: "0%")
        XCTAssertNil(missing.normalizedValue)
        XCTAssertNil(invalid.normalizedValue)
        XCTAssertEqual(zero.normalizedValue, 0)
        XCTAssertEqual(missing.color, .secondary)
        XCTAssertEqual(invalid.color, .secondary)
        XCTAssertEqual(zero.color, .green)
        XCTAssertEqual(invalid.displayText, "—")
    }

    @MainActor func testStoppedBrowserCheckClearsBusyState() {
        let model = ChromePagesModel(app: "Fixture browser", appMemoryKB: nil, gpuKB: nil)
        model.start(measure: true)
        XCTAssertTrue(model.running)
        XCTAssertTrue(model.measuring)
        model.stop()
        XCTAssertFalse(model.running)
        XCTAssertFalse(model.measuring)
        XCTAssertTrue(model.stopped)
        XCTAssertNil(model.phase)
    }
}
