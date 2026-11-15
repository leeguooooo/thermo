import XCTest
import UserNotifications
@testable import ThermoShell
@testable import ThermoComposition

final class NotificationAccessTests: ThermoCompositionTestCase {
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
