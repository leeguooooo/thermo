import XCTest
@testable import ToolExtensionCore

final class ToolExtensionConfigurationTests: XCTestCase {
    let menu = ToolExtensionDescriptor(id: "builtin.menubar", title: "Menu bar", symbol: "menubar.rectangle", summary: "Manage menu bar")
    let other = ToolExtensionDescriptor(id: "thirdparty.example", title: "Example", symbol: "star", summary: "Example", defaultEnabled: false)

    func testDefaultsAndDisabledProvidersAreDistinctFromMenuVisibility() {
        var config = ToolExtensionConfiguration()
        XCTAssertTrue(config.preference(for: menu).enabled)
        XCTAssertFalse(config.preference(for: other).enabled)
        config.extensions[menu.id] = .init(enabled: true, showInMenu: false)
        XCTAssertTrue(config.preference(for: menu).enabled)
        XCTAssertTrue(config.ordered([menu, other], menuOnly: true).isEmpty)
        XCTAssertEqual(config.ordered([other, menu]).map(\.id), [menu.id, other.id])
    }
    func testUserOrderAndStableTies() {
        var config = ToolExtensionConfiguration(extensions: [other.id: .init(order: -10)])
        XCTAssertEqual(config.ordered([menu, other]).map(\.id), [other.id, menu.id])
        config.extensions[other.id]?.order = 0
        XCTAssertEqual(config.ordered([other, menu]).map(\.id), [menu.id, other.id])
    }
    func testRoundTripKeepsSettingsForAbsentExtensions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ToolExtensionConfigurationStore(url: root.appendingPathComponent("Extensions/settings.json"))
        XCTAssertEqual(try store.read(), ToolExtensionConfiguration())
        let config = ToolExtensionConfiguration(extensions: ["temporarily.absent": .init(enabled: false, showInMenu: false, order: 24)])
        try store.write(config)
        XCTAssertEqual(try store.read(), config)
    }
    func testMalformedFutureAndOversizedFilesArePreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ToolExtensionConfigurationStore(url: root.appendingPathComponent("settings.json"))
        for data in [Data("broken".utf8), Data("{\"schemaVersion\":99,\"extensions\":{}}".utf8), Data(repeating: 32, count: 65_537)] {
            try data.write(to: store.url)
            XCTAssertThrowsError(try store.read())
            XCTAssertEqual(try Data(contentsOf: store.url), data)
        }
    }
    func testInvalidIDsDoNotReplaceGoodConfiguration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ToolExtensionConfigurationStore(url: root.appendingPathComponent("settings.json"))
        let original = ToolExtensionConfiguration(extensions: [menu.id: .init(enabled: false)])
        try store.write(original)
        for id in ["", "../script", "id with space", "org.example\n"] {
            XCTAssertThrowsError(try store.write(.init(extensions: [id: .init()])))
            XCTAssertEqual(try store.read(), original)
        }
    }
}
