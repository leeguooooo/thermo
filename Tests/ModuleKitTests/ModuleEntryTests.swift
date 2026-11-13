import Foundation
import XCTest
@testable import ModuleKit

final class ModuleEntryTests: XCTestCase {
    func manifest(_ entries: [ModuleManifest.Entry]) -> ModuleManifest {
        .init(id: "com.example.entries", name: "Entries", summary: "UI entries", symbol: "folder", version: "1.0.0", entries: entries)
    }
    func testOldEntryJSONStillLoadsWithoutNewOptionalFields() throws {
        let data = Data(#"{"interface":1,"id":"com.example.entries","name":"Old","summary":"","symbol":"folder","version":"1.0.0","launch":"onDemand","enabledByDefault":false,"capabilities":[],"entries":[{"id":"home","kind":"page","title":"Home","scene":"main"}],"commands":[]}"#.utf8)
        let loaded = try ModuleManifest.load(data)
        XCTAssertNil(loaded.entries[0].parent)
        XCTAssertNil(loaded.entries[0].navigationKey)
        XCTAssertEqual(loaded.interface, 1)
    }
    func testTreeShortcutAndSettingsSceneRoundTrip() throws {
        let m = manifest([.init(id: "home", kind: .page, title: "Home", scene: "main", navigationKey: "5"),
                          .init(id: "child", kind: .page, title: "Child", scene: "child", parent: "home"),
                          .init(id: "settings", kind: .settingsItem, title: "Settings", scene: "settings")])
        XCTAssertEqual(try ModuleManifest.load(JSONEncoder().encode(m)), m)
        XCTAssertTrue(m.entries[2].kind.showsUI)
    }
    func testBadParentsAndCyclesAreRefusedWhole() {
        for entries: [ModuleManifest.Entry] in [
            [.init(id: "one", kind: .page, title: "One", scene: "one", parent: "missing")],
            [.init(id: "one", kind: .page, title: "One", scene: "one", parent: "one")],
            [.init(id: "one", kind: .page, title: "One", scene: "one", parent: "two"), .init(id: "two", kind: .page, title: "Two", scene: "two", parent: "one")],
            [.init(id: "settings", kind: .settingsItem, title: "Settings", scene: "settings"), .init(id: "one", kind: .page, title: "One", scene: "one", parent: "settings")]
        ] {
            XCTAssertFalse(manifest(entries).problems().isEmpty)
        }
    }
    func testOnlySingleDigitPageNavigationAndUniqueKeysAreAllowed() {
        for key in ["", "10", "q", "５"] {
            XCTAssertFalse(manifest([.init(id: "one", kind: .page, title: "One", scene: "one", navigationKey: key)]).problems().isEmpty)
        }
        let duplicates = manifest([.init(id: "one", kind: .page, title: "One", scene: "one", navigationKey: "5"),
                                   .init(id: "two", kind: .page, title: "Two", scene: "two", navigationKey: "5")])
        XCTAssertTrue(duplicates.problems().contains("navigation key 5 is defined twice"))
        XCTAssertFalse(manifest([.init(id: "settings", kind: .settingsItem, title: "Settings", scene: "settings", navigationKey: "5")]).problems().isEmpty)
    }
}

final class ModuleNavigationTests: XCTestCase {
    func feature(_ id: String, _ key: String) -> ModuleManifest {
        .init(id: id, name: id, summary: "", symbol: "folder", version: "1.0.0", entries: [
            .init(id: "home", kind: .page, title: "Home", scene: "main", navigationKey: key)
        ])
    }
    func testCoreSlotsCannotBeClaimedByAModule() {
        let m = feature("com.example.one", "1")
        let conflict = ModuleNavigation.conflicts([m]).first
        XCTAssertEqual(conflict?.key, "1")
        XCTAssertNil(conflict?.owner)
        XCTAssertEqual(conflict?.module, m.id)
    }
    func testOnlyTheProvidedActiveSetClaimsSlots() {
        let one = feature("com.example.one", "5"), two = feature("com.example.two", "5")
        XCTAssertTrue(ModuleNavigation.conflicts([one]).isEmpty)
        XCTAssertEqual(ModuleNavigation.conflicts([one, two]).first?.owner, one.id)
        XCTAssertTrue(ModuleNavigation.conflicts([two]).isEmpty, "Disabling one feature releases its slot")
    }
}
