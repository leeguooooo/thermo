import XCTest
@testable import ThermoApp

@MainActor final class MenuBarShortcutTests: XCTestCase {
    final class Lease: CleanScreenHotkeyLease {
        var releases = 0
        var fails = false
        func release() throws {
            releases += 1
            if fails { throw NSError(domain: "MenuBarShortcutTest", code: 2) }
        }
    }
    final class Backend: CleanScreenHotkeyBackend {
        var callbacks: [(Bool) -> Void] = []
        var leases: [Lease] = []
        var failAt: Int?
        var attempts = 0
        func register(_ binding: CleanScreenKeyBinding, event: @escaping (Bool) -> Void) throws -> any CleanScreenHotkeyLease {
            attempts += 1
            if attempts == failAt { throw NSError(domain: "MenuBarShortcutTest", code: 1) }
            XCTAssertTrue(binding.valid)
            callbacks.append(event)
            let lease = Lease(); leases.append(lease); return lease
        }
    }

    func testRequiresUserChoiceAndActiveModuleAndSuppressesHeldKeys() {
        let suite = "MenuBarShortcutTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = Backend(); var toggles = 0; var restores = 0
        let model = MenuBarShortcuts(defaults: defaults, backend: backend, toggle: { toggles += 1 }, restore: { restores += 1 })
        defer { model.shutdown() }
        model.setRequested(true)
        XCTAssertEqual(backend.attempts, 0)
        model.setEligible(true)
        XCTAssertTrue(model.active)
        XCTAssertEqual(backend.attempts, 2)
        backend.callbacks[0](true); backend.callbacks[0](true)
        XCTAssertEqual(toggles, 1)
        backend.callbacks[0](false); backend.callbacks[0](true)
        backend.callbacks[1](true); backend.callbacks[1](true)
        XCTAssertEqual(toggles, 2); XCTAssertEqual(restores, 1)
        model.setEligible(false)
        XCTAssertFalse(model.active)
        XCTAssertEqual(backend.leases.map(\.releases), [1, 1])
        backend.callbacks[0](false); backend.callbacks[0](true); backend.callbacks[1](true)
        XCTAssertEqual(toggles, 2); XCTAssertEqual(restores, 1)
        XCTAssertTrue(defaults.bool(forKey: MenuBarShortcuts.preferenceKey))
    }

    func testSecondConflictRollsBackFirstLeaseAndAllowsExplicitRetry() {
        let suite = "MenuBarShortcutTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = Backend(); backend.failAt = 2
        var actions = 0
        let model = MenuBarShortcuts(defaults: defaults, backend: backend, toggle: { actions += 1 }, restore: {})
        defer { model.shutdown() }
        model.setRequested(true); model.setEligible(true)
        XCTAssertFalse(model.active); XCTAssertNotNil(model.issue); XCTAssertFalse(model.uncertain)
        XCTAssertEqual(backend.leases[0].releases, 1)
        model.setEligible(true)
        XCTAssertEqual(backend.attempts, 2, "Unrelated state refreshes must not retry a conflict")
        backend.failAt = nil; model.retry()
        XCTAssertTrue(model.active); XCTAssertNil(model.issue)
        backend.callbacks[0](true)
        XCTAssertEqual(actions, 0, "Abandoned registration callbacks stay invalid")
        backend.callbacks[1](true)
        XCTAssertEqual(actions, 1)
    }

    func testFailedReleaseDisablesActionsAndRetainsLeaseForShutdownRecovery() {
        let suite = "MenuBarShortcutTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = Backend(); var actions = 0
        let model = MenuBarShortcuts(defaults: defaults, backend: backend, toggle: { actions += 1 }, restore: { actions += 1 })
        model.setRequested(true); model.setEligible(true)
        backend.leases[0].fails = true
        model.setRequested(false)
        XCTAssertFalse(model.active); XCTAssertTrue(model.uncertain); XCTAssertNotNil(model.issue)
        backend.callbacks.forEach { $0(true) }
        model.setRequested(true); model.retry()
        XCTAssertEqual(actions, 0); XCTAssertEqual(backend.attempts, 2)
        backend.leases[0].fails = false
        model.shutdown()
        XCTAssertEqual(backend.leases[0].releases, 2)
        XCTAssertEqual(backend.leases[1].releases, 1)
    }

    func testDefaultDoesNotRegisterAndShutdownDoesNotEraseUserPreference() {
        let suite = "MenuBarShortcutTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = Backend()
        let model = MenuBarShortcuts(defaults: defaults, backend: backend, toggle: {}, restore: {})
        model.setEligible(true)
        XCTAssertFalse(model.requested); XCTAssertEqual(backend.attempts, 0)
        model.setRequested(true); model.shutdown()
        XCTAssertFalse(model.active)
        XCTAssertEqual(backend.leases.map(\.releases), [1, 1])
        XCTAssertTrue(defaults.bool(forKey: MenuBarShortcuts.preferenceKey))
        XCTAssertFalse(MenuBarShortcuts.toggleBinding.sameGesture(MenuBarShortcuts.restoreBinding))
    }
}
