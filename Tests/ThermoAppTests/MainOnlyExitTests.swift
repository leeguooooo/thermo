import AppKit
import XCTest
@testable import ThermoApp

final class MainOnlyExitTests: XCTestCase {
    @MainActor func testStandaloneDelegateProtectsRestoreAndHelperRemoval() {
        let delegate = MainOnlyDelegate()
        var pages: [MainPage] = []
        delegate.showExitBlocker = { pages.append($0) }
        let restore = AppExitGuard.beginRestore()
        let helper = AppExitGuard.beginHelperMaintenance()
        defer { AppExitGuard.endRestore(restore); AppExitGuard.endHelperMaintenance(helper) }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertEqual(pages, [.history])
        AppExitGuard.endRestore(restore)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertEqual(pages, [.history, .settings])
        AppExitGuard.endHelperMaintenance(helper)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
    }

    @MainActor func testStandaloneDelegateNotifiesConfirmedManualRemovalUntilItFinishes() {
        let delegate = MainOnlyDelegate()
        var pages: [MainPage] = [], notices = 0
        delegate.showExitBlocker = { pages.append($0) }
        let token = AppExitGuard.beginManualRemoval { notices += 1 }
        defer { AppExitGuard.endManualRemoval(token) }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertEqual(notices, 1)
        XCTAssertEqual(pages, [.space(.browse)])
        AppExitGuard.endManualRemoval(token)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        XCTAssertEqual(notices, 1)
    }

    @MainActor func testActualWindowCloseUsesGuardAfterCloseAndIgnoresOtherWindows() async {
        _ = NSApplication.shared
        func makeWindow() -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 800, height: 580),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.orderBack(nil)
            return window
        }
        for kind in ["restore", "helper", "manual", "idle"] {
            let window = makeWindow(), unrelated = makeWindow()
            let delegate = MainOnlyDelegate()
            var pages: [MainPage] = [], notices = 0, requests = 0
            delegate.showExitBlocker = { pages.append($0) }
            let token: UUID?
            switch kind {
            case "restore": token = AppExitGuard.beginRestore()
            case "helper": token = AppExitGuard.beginHelperMaintenance()
            case "manual": token = AppExitGuard.beginManualRemoval { notices += 1 }
            default: token = nil
            }
            defer {
                if let token {
                    AppExitGuard.endRestore(token)
                    AppExitGuard.endHelperMaintenance(token)
                    AppExitGuard.endManualRemoval(token)
                }
                window.orderOut(nil)
                unrelated.orderOut(nil)
            }
            let requested = expectation(description: kind + " close requests termination")
            let observer = MainOnlyDelegate.observeMainWindowClosing(window: { window }) {
                requests += 1
                XCTAssertFalse(window.isVisible, "run after the close has finished")
                XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared),
                               kind == "idle" ? .terminateNow : .terminateCancel)
                requested.fulfill()
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            unrelated.close()
            // The shared close observer must not treat a sheet/other window as the main one.
            await Task.yield()
            XCTAssertEqual(requests, 0)
            window.close()
            await fulfillment(of: [requested], timeout: 2)
            XCTAssertEqual(requests, 1)
            switch kind {
            case "restore": XCTAssertEqual(pages, [.history])
            case "helper": XCTAssertEqual(pages, [.settings])
            case "manual": XCTAssertEqual(pages, [.space(.browse)]); XCTAssertEqual(notices, 1)
            default: XCTAssertTrue(pages.isEmpty)
            }
        }
    }

}
