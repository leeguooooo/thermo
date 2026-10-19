import AppKit
import XCTest
@testable import ThermoApp

final class MainOnlyExitTests: XCTestCase {
    @MainActor func testStandaloneDelegateProtectsRestoreAndHelperRemoval() {
        let delegate = MainOnlyDelegate()
        var pages: [MainPage] = []
        delegate.showExitBlocker = { pages.append($0) }
        let restore = AppExitGuard.beginRestore()
        let helper = AppExitGuard.beginHelperRemoval()
        defer { AppExitGuard.endRestore(restore); AppExitGuard.endHelperRemoval(helper) }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertEqual(pages, [.history])
        AppExitGuard.endRestore(restore)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertEqual(pages, [.history, .settings])
        AppExitGuard.endHelperRemoval(helper)
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
}
