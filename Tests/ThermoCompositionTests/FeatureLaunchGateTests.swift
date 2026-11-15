import AppKit
import XCTest
@testable import ThermoShell
@testable import ThermoComposition

@MainActor final class FeatureLaunchGateTests: ThermoCompositionTestCase {
    func testFirstMainLaunchDefersStartupAndRunsItOnlyOnceAfterSelection() {
        let gate = FeatureLaunchGate()
        var finished: (@MainActor () -> Void)?
        var presentations = 0, starts = 0
        gate.launch(needsSelection: true, present: { completion in
            presentations += 1
            finished = completion
        }, run: { starts += 1 })
        XCTAssertTrue(gate.isSelecting)
        XCTAssertEqual(starts, 0, "main window and optional prewarm must wait")
        gate.launch(needsSelection: true, present: { _ in presentations += 1 }, run: { starts += 1 })
        XCTAssertEqual(presentations, 1)
        finished?()
        XCTAssertFalse(gate.isSelecting)
        XCTAssertEqual(starts, 1)
        finished?()
        gate.launch(needsSelection: true, present: { _ in presentations += 1 }, run: { starts += 1 })
        XCTAssertEqual(presentations, 1)
        XCTAssertEqual(starts, 1, "continuation cannot recurse into the selector or startup")
    }

    func testUpgradeMainLaunchDoesNotPresentSelection() {
        let gate = FeatureLaunchGate()
        var presentations = 0, starts = 0
        gate.launch(needsSelection: false, present: { _ in presentations += 1 }, run: { starts += 1 })
        XCTAssertEqual(presentations, 0)
        XCTAssertEqual(starts, 1)
        XCTAssertFalse(gate.isSelecting)
    }

    func testMainOnlyReopenFrontsSelectionAndNeverOpensMainUntilSelectionEnds() {
        let delegate = MainOnlyDelegate()
        var selecting = true, reopens = 0, mainOpens = 0
        delegate.reopenFeatureSelection = { reopens += 1; return selecting }
        delegate.showMainWindow = { mainOpens += 1 }
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        XCTAssertEqual(reopens, 1)
        XCTAssertEqual(mainOpens, 0)
        selecting = false
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        XCTAssertEqual(mainOpens, 1)
    }

    func testOrdinaryAppReopenAlsoFrontsSelectionWithoutConstructingMainWindow() {
        let delegate = AppDelegate()
        var reopens = 0, mainOpens = 0
        delegate.reopenFeatureSelection = { reopens += 1; return true }
        delegate.showMainWindow = { mainOpens += 1 }
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        XCTAssertEqual(reopens, 1)
        XCTAssertEqual(mainOpens, 0)
    }

    func testQuittingDuringMainOnlySelectionSkipsNormalFeatureGuardsAndShutdown() {
        let delegate = MainOnlyDelegate()
        delegate.featureLaunch.launch(needsSelection: true, present: { _ in }, run: { XCTFail("started main before selection") })
        var blockerShown = false
        delegate.showExitBlocker = { _ in blockerShown = true }
        let restore = AppExitGuard.beginRestore()
        defer { AppExitGuard.endRestore(restore) }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        XCTAssertFalse(blockerShown)
        // No selection window, real defaults, feature startup, or normal feature cleanup is needed.
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    }
}
