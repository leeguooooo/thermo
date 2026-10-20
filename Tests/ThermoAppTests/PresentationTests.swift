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
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let target = NSObject()
        let panel = NSMenuItem(title: "untranslated", action: NSSelectorFromString("openPanelFromMenu"), keyEquivalent: "p")
        panel.target = target; panel.keyEquivalentModifierMask = [.command, .shift]
        appMenu.addItem(panel); appItem.submenu = appMenu; NSApp.mainMenu?.addItem(appItem)
        L10n.override = .english
        installStandardMenus()
        let view = NSApp.mainMenu?.items.first { $0.identifier?.rawValue == "thermo.view" }
        XCTAssertEqual(view?.title, "View")
        XCTAssertEqual(panel.title, "Open Menu Panel")
        XCTAssertTrue(panel.target === target)
        let items = view?.submenu?.items ?? []
        XCTAssertEqual(items.map(\.keyEquivalent), ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "", "", ","])
        for page in [MainPage.apps(.installed), .memory, .compute(false), .compute(true), .space(.browse), .claudeCleanup] {
            XCTAssertEqual(items.filter { ($0.representedObject as? MainPage) == page }.count, 1)
        }
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
        XCTAssertEqual(panel.title, "打开菜单小面板")
        XCTAssertEqual(panel.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertEqual(appMenu.items.count, 1)
        XCTAssertTrue(panel.target === target)
    }

    @MainActor func testPanelStopReleasesOnlyItsLeaseAndRejectsLateSampling() {
        var samples = 0, holders = 1 // A separate visible Overview owns its own lease.
        var reading = PanelModel.Reading(cpu: 70, gpu: 8, download: 100, upload: 25)
        let panel = PanelModel(readSample: { samples += 1; return reading },
                               holdPulse: { holders += 1 }, releasePulse: { holders -= 1 })
        panel.sample()
        XCTAssertEqual(samples, 0)
        panel.setActive(true); panel.setActive(true)
        XCTAssertTrue(panel.samplingActive)
        XCTAssertEqual(samples, 1); XCTAssertEqual(holders, 2)
        XCTAssertEqual(panel.currentCPU, 70); XCTAssertEqual(panel.currentGPU, 8)
        panel.setActive(false); panel.setActive(false)
        panel.sample() // A delayed callback must not restart hidden work.
        XCTAssertFalse(panel.samplingActive)
        XCTAssertEqual(samples, 1); XCTAssertEqual(holders, 1)
        XCTAssertNil(panel.currentCPU); XCTAssertNil(panel.currentGPU); XCTAssertNil(panel.currentDownload)
        XCTAssertEqual(panel.cpu, [70], "retained history must be separate from current values")
        reading = .init(gpu: .nan)
        panel.setActive(true)
        XCTAssertNil(panel.currentCPU); XCTAssertNil(panel.currentGPU)
        XCTAssertEqual(panel.cpu, [70])
        panel.setActive(false)
        XCTAssertEqual(holders, 1)
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

    @MainActor func testMinimumWindowSizeCanBeRestored() {
        let frame = NSRect(origin: NSPoint(x: 100, y: 100), size: MainWindow.minimumContentSize)
        XCTAssertTrue(MainWindow.usableFrame(frame, screens: [NSRect(x: 0, y: 0, width: 1920, height: 1080)]))
    }

    @MainActor func testBarelyVisibleWindowAndHiddenTitlebarAreNotUsable() {
        let screen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertFalse(MainWindow.usableFrame(NSRect(x: -1099, y: 100, width: 1100, height: 740), screens: [screen]))
        XCTAssertFalse(MainWindow.usableFrame(NSRect(x: 100, y: 1000, width: 1100, height: 740), screens: [screen]))
        XCTAssertFalse(MainWindow.usableFrame(NSRect(x: 100, y: 600, width: 1100, height: 740), screens: [screen]))
        XCTAssertTrue(MainWindow.usableFrame(NSRect(x: -100, y: 100, width: 1100, height: 740), screens: [screen]))
    }

    @MainActor func testWindowCanStayOnASecondaryDisplayAndRejectsInvalidGeometry() {
        let screens = [NSRect(x: 0, y: 0, width: 1920, height: 1080), NSRect(x: -1920, y: 0, width: 1920, height: 1080)]
        XCTAssertTrue(MainWindow.usableFrame(NSRect(x: -1800, y: 100, width: 1100, height: 740), screens: screens))
        XCTAssertFalse(MainWindow.usableFrame(NSRect(x: CGFloat.infinity, y: 100, width: 1100, height: 740), screens: screens))
    }

    @MainActor func testOversizedFrameRecoversAfterLargeDisplayIsRemoved() {
        let primary = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let second = NSRect(x: 1920, y: 0, width: 1920, height: 1080)
        let frame = NSRect(x: 100, y: 100, width: 2400, height: 740)
        XCTAssertTrue(MainWindow.usableFrame(frame, screens: [primary, second]))
        XCTAssertFalse(MainWindow.usableFrame(frame, screens: [primary]))
        XCTAssertFalse(MainWindow.usableFrame(frame, screens: []))
    }

    @MainActor func testLanguageSwitchRelocalizesDiskTitlesWithoutRescanning() {
        L10n.override = .english
        defer { L10n.override = nil }
        var overview = SpaceOverview(capacity: 100, free: 25, purgeable: 0,
                                     entries: [.init(id: "apps", title: "Applications", bytes: 10, children: [])], duration: 1)
        overview.language = "en"
        let model = SpaceOverviewModel(cached: (overview, Date()))
        XCTAssertEqual(model.entries.count, 1)
        L10n.override = .simplifiedChinese
        model.discardIncompatibleResults()
        XCTAssertEqual(model.entries.first?.title, tr("Applications"))
        XCTAssertEqual(model.entries.first?.bytes, 10)
        XCTAssertEqual(model.overview?.language, "zh-Hans")
        XCTAssertNotNil(model.measuredAt)
        XCTAssertFalse(model.measuring)
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
