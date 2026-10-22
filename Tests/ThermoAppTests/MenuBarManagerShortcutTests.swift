import XCTest
import MenuBarCore
@testable import ThermoApp

@MainActor final class MenuBarManagerShortcutTests: XCTestCase {
    private func model() throws -> (String, UserDefaults, MenuBarShortcutTests.Backend, MenuBarManager) {
        let suite = "MenuBarManagerShortcutTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let backend = MenuBarShortcutTests.Backend()
        let model = MenuBarManager(defaults: defaults, accessibilityTrusted: { true }, shortcutBackend: backend)
        guard model.available else {
            defaults.removePersistentDomain(forName: suite)
            throw XCTSkip("Native menu management requires macOS 27")
        }
        defaults.set(true, forKey: MenuBarManager.enabledKey)
        defaults.set(true, forKey: MenuBarShortcuts.preferenceKey)
        return (suite, defaults, backend, model)
    }

    func testToggleAndRestoreKeepAssignmentsAndDisablingReleasesShortcuts() throws {
        let (suite, defaults, backend, model) = try model()
        defer { model.shutdown(); defaults.removePersistentDomain(forName: suite) }
        model.start()
        XCTAssertTrue(model.shortcuts.active)
        // This UUID is not running; no visibility assertion is activated.
        model.assign("org.example.menubar-absent." + UUID().uuidString, to: .hidden)
        let saved = defaults.data(forKey: MenuBarSectionStore.key)
        backend.callbacks[0](true)
        XCTAssertEqual(model.reveal, .collapsed)
        backend.callbacks[0](false); backend.callbacks[0](true)
        XCTAssertEqual(model.reveal, .hidden)
        backend.callbacks[1](true)
        XCTAssertEqual(model.reveal, .all)
        XCTAssertEqual(defaults.data(forKey: MenuBarSectionStore.key), saved)
        model.setEnabled(false)
        XCTAssertFalse(model.shortcuts.active)
        XCTAssertEqual(backend.leases.map(\.releases), [1, 1])
        backend.callbacks[0](false); backend.callbacks[0](true)
        XCTAssertEqual(model.reveal, .all)
    }

    func testFailedVisibilityKeepsRecoveryKeyUntilRestored() throws {
        let (suite, defaults, backend, model) = try model()
        defer { model.shutdown(); defaults.removePersistentDomain(forName: suite) }
        model.start()
        model.handleVisibilityState(.failed("injected recovery failure"))
        XCTAssertFalse(model.enabled)
        XCTAssertTrue(model.shortcuts.active)
        backend.callbacks[0](true)
        XCTAssertEqual(model.reveal, .all, "Disabled management cannot hide through a shortcut")
        backend.callbacks[1](true)
        XCTAssertEqual(model.state, .visible)
        XCTAssertFalse(model.shortcuts.active)
        XCTAssertEqual(backend.leases.map(\.releases), [1, 1])
    }

    func testShutdownDoesNotReregisterAfterALateFailure() throws {
        let (suite, defaults, backend, model) = try model()
        defer { model.shutdown(); defaults.removePersistentDomain(forName: suite) }
        model.start()
        model.shutdown()
        model.handleVisibilityState(.failed("injected late failure"))
        XCTAssertFalse(model.shortcuts.active)
        XCTAssertEqual(backend.attempts, 2)
        XCTAssertEqual(backend.leases.map(\.releases), [1, 1])
    }
}
