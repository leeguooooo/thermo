import Foundation
import XCTest
@testable import ThermoKit
@testable import ThermoApp

final class VerificationHelperIsolationTests: XCTestCase {
    @MainActor func testVerificationModesNeverCreateAHelperConnection() async {
        for flag in ["--offscreen", "--snapshot", "--render-preview", "--verify-lifecycle"] {
            let unexpected = expectation(description: "no helper connection for " + flag)
            unexpected.isInverted = true
            let client = HelperClient(makeConnection: {
                unexpected.fulfill()
                return NSXPCConnection(machServiceName: "dev.thermo.qa.absent." + UUID().uuidString)
            })
            let monitor = Monitor(startMonitoring: false, helper: client,
                                  arguments: ["Thermo", "--main", flag])
            monitor.refreshHelper()
            await fulfillment(of: [unexpected], timeout: 0.05)
        }
    }

    @MainActor func testInteractiveRefreshStillUsesInjectedClientAndExplicitDisableWins() async {
        let called = expectation(description: "interactive helper connection")
        let client = HelperClient(makeConnection: {
            called.fulfill()
            return NSXPCConnection(machServiceName: "dev.thermo.qa.absent." + UUID().uuidString)
        })
        let monitor = Monitor(startMonitoring: false, helper: client, arguments: ["Thermo", "--main"])
        monitor.refreshHelper()
        await fulfillment(of: [called], timeout: 1)

        let unexpected = expectation(description: "explicitly disabled helper connection")
        unexpected.isInverted = true
        let disabled = Monitor(startMonitoring: false, helperInteraction: false,
            helper: HelperClient(makeConnection: {
                unexpected.fulfill()
                return NSXPCConnection(machServiceName: "dev.thermo.qa.absent." + UUID().uuidString)
            }), arguments: ["Thermo", "--main"])
        disabled.refreshHelper()
        await fulfillment(of: [unexpected], timeout: 0.05)
    }
}
