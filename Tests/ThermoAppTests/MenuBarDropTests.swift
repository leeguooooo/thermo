import XCTest
import MenuBarCore
@testable import ThermoApp

@MainActor final class MenuBarDropTests: XCTestCase {
    private let apps = [ManagedMenuBarApp(id: "org.example.first", name: "First"), ManagedMenuBarApp(id: "org.example.second", name: "Second")]
    func testDragAcrossGroupsPersistsAndDoesNotEnableNativeHiding() throws {
        let suite = "MenuBarDropTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = MenuBarManager(defaults: defaults, initialApps: apps)
        guard model.available else { throw XCTSkip("Native management requires macOS 27") }
        let data = try XCTUnwrap(model.dragData(for: apps[0].id))
        for section in [MenuBarSection.hidden, .alwaysHidden, .visible] {
            XCTAssertTrue(model.acceptDrop(data, into: section))
            XCTAssertEqual(model.sections[apps[0].id], section)
            XCTAssertEqual(try MenuBarSectionStore(defaults: defaults).read()[apps[0].id], section)
            XCTAssertEqual(model.sections[apps[1].id], .visible)
            XCTAssertFalse(model.enabled)
            XCTAssertEqual(model.state, .visible)
        }
    }
    func testInvalidDropPreservesExistingGroups() throws {
        let suite = "MenuBarDropTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = MenuBarManager(defaults: defaults, initialApps: apps)
        guard model.available else { throw XCTSkip("Native management requires macOS 27") }
        model.assign(apps[0].id, to: .hidden)
        let before = try MenuBarSectionStore(defaults: defaults).read()
        let data = try JSONEncoder().encode(MenuBarDragPayload(bundle: "org.example.unregistered"))
        XCTAssertFalse(model.acceptDrop(data, into: .alwaysHidden))
        XCTAssertEqual(try MenuBarSectionStore(defaults: defaults).read(), before)
        XCTAssertNotNil(model.error)
    }
    func testUnreadablePreferencesCannotBeOverwrittenByDrop() throws {
        let suite = "MenuBarDropTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let corrupt = Data("corrupt".utf8)
        defaults.set(corrupt, forKey: MenuBarSectionStore.key)
        let model = MenuBarManager(defaults: defaults, initialApps: apps)
        let data = try JSONEncoder().encode(MenuBarDragPayload(bundle: apps[0].id))
        XCTAssertNil(model.dragData(for: apps[0].id))
        XCTAssertFalse(model.acceptDrop(data, into: .hidden))
        XCTAssertEqual(defaults.data(forKey: MenuBarSectionStore.key), corrupt)
    }
}
