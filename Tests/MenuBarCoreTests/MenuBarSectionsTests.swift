import XCTest
@testable import MenuBarCore

final class MenuBarSectionsTests: XCTestCase {
    let running: Set<String> = ["org.example.chat", "org.example.sync", "org.example.new", "dev.thermo.app", "com.apple.controlcenter"]

    func testRevealStatesKeepAssignmentsAndAlwaysHiddenSeparate() {
        var sections = MenuBarSections()
        sections.assign("org.example.chat", to: .hidden)
        sections.assign("org.example.sync", to: .alwaysHidden)
        let saved = sections
        XCTAssertEqual(sections.hiddenBundles(reveal: .collapsed), ["org.example.chat", "org.example.sync"])
        XCTAssertEqual(sections.hiddenBundles(reveal: .hidden), ["org.example.sync"])
        XCTAssertTrue(sections.hiddenBundles(reveal: .all).isEmpty)
        XCTAssertEqual(sections, saved)
    }

    func testConfigurationPreservesNewAppsSystemItemsAndOwnIdentity() {
        let sections = MenuBarSections(assignments: ["org.example.chat": .hidden, "org.example.sync": .alwaysHidden])
        let config = sections.configuration(running: running, ownBundle: "dev.thermo.app", reveal: .hidden)
        XCTAssertEqual(Set(config!.allowedBundles), running.subtracting(["org.example.sync"]))
        XCTAssertNil(sections.configuration(running: running, ownBundle: "dev.thermo.app", reveal: .all))
    }

    func testAbsentAppsDoNotActivateAndRejoinSavedSectionOnLaunch() {
        let sections = MenuBarSections(assignments: ["org.example.absent": .hidden])
        XCTAssertNil(sections.configuration(running: running, ownBundle: "dev.thermo.app", reveal: .collapsed))
        let started = running.union(["org.example.absent"])
        XCTAssertEqual(Set(sections.configuration(running: started, ownBundle: "dev.thermo.app", reveal: .collapsed)!.allowedBundles), running)
        XCTAssertEqual(sections["org.example.absent"], .hidden)
    }

    func testProtectedAndInvalidIDsCannotHideRecoveryOrSystemControls() throws {
        let invalid = ["", "pid:123", "window:34", "org..bad", "a.", " white.space", "org.a\n", "com.apple.controlcenter", "dev.thermo.app", "dev.thermo.menubarqa.123"]
        var sections = MenuBarSections(assignments: Dictionary(uniqueKeysWithValues: invalid.map { ($0, .hidden) }))
        for bundle in invalid {
            XCTAssertFalse(MenuBarSections.isAssignable(bundle), bundle)
            sections.assign(bundle, to: .alwaysHidden)
            XCTAssertEqual(sections[bundle], .visible)
        }
        XCTAssertTrue(sections.assignments.isEmpty)
        let decoded = try JSONDecoder().decode(MenuBarSections.self, from: Data("{\"assignments\":{\"dev.thermo.app\":\"hidden\",\"org.example.good\":\"hidden\"}}".utf8))
        XCTAssertEqual(decoded.assignments, ["org.example.good": .hidden])
    }

    func testOwnIdentityIsProtectedEvenIfFutureBrandUsesAnotherNamespace() {
        let sections = MenuBarSections(assignments: ["org.example.host": .hidden])
        XCTAssertNil(sections.configuration(running: ["org.example.host"], ownBundle: "org.example.host", reveal: .collapsed))
    }

    func testVisibleAssignmentRemovesOverrideAndPersistenceRoundTrips() throws {
        let suite = "MenuBarSectionsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MenuBarSectionStore(defaults: defaults)
        XCTAssertEqual(try store.read(), MenuBarSections())
        var sections = MenuBarSections(assignments: ["org.example.chat": .hidden, "org.example.absent": .alwaysHidden])
        try store.write(sections)
        XCTAssertEqual(try store.read(), sections)
        sections.assign("org.example.chat", to: .visible)
        XCTAssertNil(sections.assignments["org.example.chat"])
        try store.write(sections)
        XCTAssertEqual(try store.read(), sections)
    }

    func testCorruptOrFuturePreferencesAreReportedAndNeverOverwrittenByRead() {
        let suite = "MenuBarSectionsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MenuBarSectionStore(defaults: defaults)
        let future = Data("{\"assignments\":{\"org.example.chat\":\"futureSection\"}}".utf8)
        defaults.set(future, forKey: MenuBarSectionStore.key)
        XCTAssertThrowsError(try store.read())
        XCTAssertEqual(defaults.data(forKey: MenuBarSectionStore.key), future)
        defaults.set("corrupt", forKey: MenuBarSectionStore.key)
        XCTAssertThrowsError(try store.read())
        XCTAssertEqual(defaults.string(forKey: MenuBarSectionStore.key), "corrupt")
    }
}
