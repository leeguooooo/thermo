import XCTest
import MenuBarCore
@testable import MenuBarFeature

@MainActor final class MenuBarManagerShortcutTests: XCTestCase {
    private func model(accessibilityTrusted: @escaping @MainActor () -> Bool = { true }, controller:MenuBarSessionController? = nil) throws -> (String, UserDefaults, MenuBarShortcutTests.Backend, MenuBarManager) {
        let suite = "MenuBarManagerShortcutTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let backend = MenuBarShortcutTests.Backend()
        let model = MenuBarManager(defaults: defaults, accessibilityTrusted: accessibilityTrusted, shortcutBackend: backend,controller:controller,capabilityAvailable:{true})
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

    func testPermissionRevocationReleasesShortcutsAfterRestoringVisibility() throws {
        var trusted = true
        let (suite, defaults, backend, model) = try model(accessibilityTrusted: { trusted })
        defer { model.shutdown(); defaults.removePersistentDomain(forName: suite) }
        model.start()
        XCTAssertTrue(model.shortcuts.active)
        model.assign("org.example.menubar-absent." + UUID().uuidString, to: .hidden)
        let saved = defaults.data(forKey: MenuBarSectionStore.key)

        trusted = false
        model.setReveal(.collapsed)

        XCTAssertFalse(model.enabled)
        XCTAssertFalse(defaults.bool(forKey: MenuBarManager.enabledKey))
        XCTAssertEqual(model.state, .visible)
        XCTAssertFalse(model.shortcuts.active)
        XCTAssertEqual(backend.leases.map(\.releases), [1, 1])
        XCTAssertEqual(defaults.data(forKey: MenuBarSectionStore.key), saved)
        backend.callbacks[0](true)
        XCTAssertEqual(model.state, .visible)
    }

    func testFailedVisibilityKeepsRecoveryKeyUntilRestored() throws {
        let controller=MenuBarSessionController{_ in throw NSError(domain:"Injected menu-bar recovery",code:1)}
        let (suite, defaults, backend, model) = try model(controller:controller)
        defer { model.shutdown(); defaults.removePersistentDomain(forName: suite) }
        model.start()
        model.restoreAll() // Adopt the injected controller before delivering its real failure callback.
        controller.apply(.init(allowedBundles:["org.example.fixture"]))
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
