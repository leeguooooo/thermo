import XCTest
@testable import ThermoApp

final class HelperUpgradeCoordinatorTests: XCTestCase {
    @MainActor func testPasswordInstalledHelperIsNeverUnregisteredAndDoesNotConsumeManagedRetry() async throws {
        let upgrade = HelperUpgradeCoordinator()
        var calls: [String] = []
        let legacy = try await upgrade.restartManaged(legacyInstalled: true,
            unregister: { calls.append("unregister") }, register: { calls.append("register") })
        XCTAssertFalse(legacy)
        XCTAssertTrue(calls.isEmpty, "preserve the running legacy job and its --source updater")
        XCTAssertFalse(upgrade.attempted)
        let managed = try await upgrade.restartManaged(legacyInstalled: false,
            unregister: { calls.append("unregister") }, register: { calls.append("register") })
        XCTAssertTrue(managed)
        XCTAssertEqual(calls, ["unregister", "register"])
        let repeated = try await upgrade.restartManaged(legacyInstalled: false,
            unregister: { calls.append("duplicate unregister") }, register: { calls.append("duplicate register") })
        XCTAssertFalse(repeated)
        XCTAssertEqual(calls.count, 2)
    }

    @MainActor func testFailedManagedUnregisterDoesNotRegisterOrRepeatDestructiveAction() async {
        let upgrade = HelperUpgradeCoordinator()
        var calls: [String] = []
        do {
            try await upgrade.restartManaged(legacyInstalled: false,
                unregister: { calls.append("unregister"); throw NSError(domain: "fixture", code: 1) },
                register: { calls.append("register") })
            XCTFail("failure must reach the caller")
        } catch {}
        XCTAssertEqual(calls, ["unregister"])
        XCTAssertTrue(upgrade.attempted)
        let again = try? await upgrade.restartManaged(legacyInstalled: false,
            unregister: { calls.append("duplicate") }, register: { calls.append("register") })
        XCTAssertEqual(again, false)
        XCTAssertEqual(calls, ["unregister"])
    }
}
