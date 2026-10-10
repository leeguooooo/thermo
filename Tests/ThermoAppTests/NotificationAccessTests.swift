import XCTest
import UserNotifications
@testable import ThermoApp

final class NotificationAccessTests: XCTestCase {
    func testMissingAndDeniedPermissionAreDistinct() {
        XCTAssertEqual(NotificationAccess.state(status: .notDetermined, alerts: .disabled), .notRequested)
        XCTAssertEqual(NotificationAccess.state(status: .denied, alerts: .enabled), .denied)
    }

    func testAuthorizationDoesNotHideDisabledBanners() {
        XCTAssertEqual(NotificationAccess.state(status: .authorized, alerts: .disabled), .bannersDisabled)
        XCTAssertEqual(NotificationAccess.state(status: .authorized, alerts: .enabled), .allowed)
        XCTAssertEqual(NotificationAccess.state(status: .provisional, alerts: .enabled), .bannersDisabled)
    }
}
