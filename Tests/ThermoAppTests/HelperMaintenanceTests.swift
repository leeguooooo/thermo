import XCTest
import ThermoKit
@testable import ThermoApp

final class HelperMaintenanceTests: XCTestCase {
    @MainActor func testInstallationBlocksQuitAndDuplicateMaintenanceUntilOperationReturns() async {
        let monitor = Monitor(startMonitoring: false, helperInteraction: false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); monitor.stopSetup() }
        let entered = expectation(description: "installer entered")
        let finished = expectation(description: "installer finished")
        let duplicate = expectation(description: "duplicate maintenance must not run")
        duplicate.isInverted = true
        monitor.performHelperInstallation(operation: {
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
        }, finished: { finished.fulfill() })
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(monitor.installingHelper)
        var pages: [MainPage] = []
        XCTAssertEqual(AppExitGuard.reply(show: { pages.append($0) }), .terminateCancel)
        XCTAssertEqual(pages, [.settings])
        monitor.performHelperInstallation(operation: { duplicate.fulfill() })
        monitor.uninstallHelper(operation: { duplicate.fulfill() })
        release.signal()
        await fulfillment(of: [finished, duplicate], timeout: 2)
        XCTAssertFalse(monitor.installingHelper)
        XCTAssertNil(monitor.lastError)
        monitor.stopSetup()
        XCTAssertEqual(AppExitGuard.reply(show: { _ in XCTFail("completed installer must release quit protection") }), .terminateNow)
    }

    @MainActor func testFailedInstallationReleasesQuitProtectionAndReportsFailure() async {
        let monitor = Monitor(startMonitoring: false, helperInteraction: false)
        let finished = expectation(description: "failed installer finished")
        monitor.performHelperInstallation(operation: {
            throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture install failure"])
        }, finished: { finished.fulfill() })
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertFalse(monitor.installingHelper)
        XCTAssertFalse(monitor.settingUp)
        XCTAssertTrue(monitor.lastError?.contains("fixture install failure") == true)
        XCTAssertEqual(AppExitGuard.reply(show: { _ in XCTFail("failed installer must release quit protection") }), .terminateNow)
    }

    @MainActor func testRemovalBlocksDuplicateRemovalAndPolicySetup() async {
        let monitor = Monitor(startMonitoring: false)
        let release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "removal finishes")
        let duplicate = expectation(description: "duplicate never runs")
        duplicate.isInverted = true
        monitor.uninstallHelper(operation: {
            _ = release.wait(timeout: .now() + 2)
        }, finished: { finished.fulfill() })
        XCTAssertTrue(monitor.uninstallingHelper)
        XCTAssertTrue(monitor.helperBusy)
        var destinations: [MainPage] = []
        XCTAssertEqual(AppExitGuard.reply(show: { destinations.append($0) }), .terminateCancel)
        XCTAssertEqual(destinations, [.settings])
        monitor.uninstallHelper(operation: { duplicate.fulfill() })
        monitor.setPolicy(.auto, fan: 0)
        monitor.beginSetup()
        XCTAssertFalse(monitor.settingUp)
        XCTAssertTrue(monitor.pendingPolicies.isEmpty)
        release.signal()
        await fulfillment(of: [finished, duplicate], timeout: 0.3)
        XCTAssertFalse(monitor.uninstallingHelper)
        XCTAssertFalse(monitor.helperBusy)
        XCTAssertNil(monitor.lastError)
        XCTAssertEqual(AppExitGuard.reply(show: { _ in XCTFail("completed removal must allow exit") }), .terminateNow)
    }

    @MainActor func testFailedRemovalReleasesBusyStateAndReportsFailure() async {
        let monitor = Monitor(startMonitoring: false)
        let finished = expectation(description: "failed removal finishes")
        monitor.uninstallHelper(operation: {
            throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture removal failure"])
        }, finished: { finished.fulfill() })
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertFalse(monitor.helperBusy)
        XCTAssertFalse(monitor.uninstallingHelper)
        XCTAssertTrue(monitor.lastError?.contains("fixture removal failure") == true)
        XCTAssertFalse(monitor.policiesAvailable)
        XCTAssertEqual(AppExitGuard.reply(show: { _ in XCTFail("failed removal must release exit guard") }), .terminateNow)
    }
}
