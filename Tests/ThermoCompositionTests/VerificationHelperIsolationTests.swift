import Foundation
import XCTest
@testable import ThermoKit
@testable import ThermoShell
@testable import ThermoComposition

final class VerificationHelperIsolationTests: ThermoCompositionTestCase {
    @MainActor func testVerificationModesNeverCreateAHelperConnection() async {
        for flag in ["--offscreen", "--snapshot", "--render-preview", "--verify-lifecycle", "--ui-review"] {
            XCTAssertTrue(AppLaunchMode.suppressesAutomaticControl(arguments: ["Thermo", "--main", flag]))
            let unexpected = expectation(description: "no helper connection for " + flag)
            unexpected.isInverted = true
            let client = HelperClient(makeConnection: {
                unexpected.fulfill()
                return NSXPCConnection(machServiceName: "dev.thermo.qa.absent." + UUID().uuidString)
            })
            let monitor = SystemPresentation(helper: client,
                                  arguments: ["Thermo", "--main", flag])
            monitor.refreshHelper()
            await fulfillment(of: [unexpected], timeout: 0.05)
        }
    }

    @MainActor func testInteractiveRefreshStillUsesInjectedClientAndExplicitDisableWins() async {
        let called = expectation(description: "interactive helper connection")
        XCTAssertFalse(AppLaunchMode.suppressesAutomaticControl(arguments: ["Thermo", "--main", "--page", "agents:mcp"]))
        let client = HelperClient(makeConnection: {
            called.fulfill()
            return NSXPCConnection(machServiceName: "dev.thermo.qa.absent." + UUID().uuidString)
        })
        let monitor = SystemPresentation(helper: client, arguments: ["Thermo", "--main"])
        monitor.refreshHelper()
        await fulfillment(of: [called], timeout: 1)

        let unexpected = expectation(description: "explicitly disabled helper connection")
        unexpected.isInverted = true
        let disabled = SystemPresentation(helperInteraction: false,
            helper: HelperClient(makeConnection: {
                unexpected.fulfill()
                return NSXPCConnection(machServiceName: "dev.thermo.qa.absent." + UUID().uuidString)
            }), arguments: ["Thermo", "--main"])
        disabled.refreshHelper()
        await fulfillment(of: [unexpected], timeout: 0.05)
    }
    @MainActor func testVisibilityOfDisabledPerformanceNeverAcquiresAnAdministrativeRefresh() async {
        let unexpected = expectation(description: "disabled view cannot create an unscoped helper connection")
        unexpected.isInverted = true
        unexpected.assertForOverFulfill = false
        let monitor = SystemPresentation(helper: HelperClient(makeConnection: {
            unexpected.fulfill()
            return NSXPCConnection(machServiceName: "dev.thermo.qa.absent." + UUID().uuidString)
        }), arguments: ["Thermo", "--main"])
        monitor.windowOpen = true
        monitor.popoverOpen = true
        await fulfillment(of: [unexpected], timeout: 0.1)
    }

}
