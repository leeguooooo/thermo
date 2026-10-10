import XCTest
import ServiceManagement
@testable import ThermoApp

final class LoginItemAccessTests: XCTestCase {
    func testStatusMappingKeepsApprovalSeparateFromDisabled() {
        XCTAssertEqual(LoginItemAccess.state(.notRegistered), .off)
        XCTAssertEqual(LoginItemAccess.state(.enabled), .enabled)
        XCTAssertEqual(LoginItemAccess.state(.requiresApproval), .needsApproval)
        XCTAssertEqual(LoginItemAccess.state(.notFound), .unavailable)
    }

    @MainActor func testPendingRegistrationIsNotRepeatedAndCanBeCancelled() {
        var status = SMAppService.Status.requiresApproval
        var registrations = 0
        var cancellations = 0
        let access = LoginItemAccess(status: { status }, register: { registrations += 1 }, unregister: {
            cancellations += 1; status = .notRegistered
        })
        access.refresh()
        XCTAssertTrue(access.requested)
        access.setRequested(true)
        XCTAssertEqual(registrations, 0)
        access.setRequested(false)
        XCTAssertEqual(cancellations, 1)
        XCTAssertFalse(access.requested)
    }

    @MainActor func testFailedRegistrationDoesNotPretendItEnabled() {
        let access = LoginItemAccess(status: { .notRegistered }, register: {
            throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture failure"])
        }, unregister: {})
        access.setRequested(true)
        XCTAssertFalse(access.requested)
        XCTAssertTrue(access.error?.contains("fixture failure") == true)
    }

    @MainActor func testRefreshReflectsApprovalFromSystemSettings() {
        var status = SMAppService.Status.requiresApproval
        let access = LoginItemAccess(status: { status }, register: {}, unregister: {})
        access.refresh()
        XCTAssertEqual(access.state, .needsApproval)
        status = .enabled
        access.refresh()
        XCTAssertEqual(access.state, .enabled)
    }
}
