import XCTest
import ThermoL10n
@testable import ThermoApp

final class PluginStatusTests: XCTestCase {
    func testClaudeInstalledPluginMustAlsoBeEnabled() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let plugin = root.appendingPathComponent(".claude/plugins/fixture-plugin")
        let fm = FileManager.default
        try fm.createDirectory(at: plugin, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let manifest: [String: Any] = ["plugins": [AgentAccess.plugin: [["scope": "user", "installPath": plugin.path]]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent(".claude/plugins/installed_plugins.json"))
        XCTAssertEqual(AgentAccess.claudeState(home: root.path), .unavailable)
        for (enabled, expected) in [(false, AgentAccess.Tool.disabled), (true, .added)] {
            try JSONSerialization.data(withJSONObject: ["enabledPlugins": [AgentAccess.plugin: enabled]])
                .write(to: root.appendingPathComponent(".claude/settings.json"))
            XCTAssertEqual(AgentAccess.claudeState(home: root.path), expected)
        }
    }

    func testAvailablePluginAndAnotherInstalledPluginDoNotCountAsInstalled() {
        XCTAssertEqual(AgentAccess.codexState(json: """
        {"installed":[{"pluginId":"another@market","installed":true,"enabled":true}],
         "available":[{"pluginId":"thermo-use@leeguooooo-plugins","installed":false,"enabled":false}]}
        """), .notAdded)
    }

    func testExactPluginIdentityAndEnabledStateAreRequired() {
        XCTAssertEqual(AgentAccess.codexState(json: """
        {"installed":[{"pluginId":"thermo-use@different-market","installed":true,"enabled":true}]}
        """), .notAdded)
        XCTAssertEqual(AgentAccess.codexState(json: """
        {"installed":[{"pluginId":"thermo-use@leeguooooo-plugins","installed":true,"enabled":false}]}
        """), .disabled)
        XCTAssertEqual(AgentAccess.codexState(json: """
        {"installed":[{"pluginId":"thermo-use@leeguooooo-plugins","installed":true,"enabled":true}]}
        """), .added)
    }

    func testMalformedOrIncompleteStatusCannotConfirmInstallation() {
        for json in ["invalid fixture", "{}", "{\"installed\":null}", "{\"installed\":[{}]}", "{\"installed\":[{\"pluginId\":\"thermo-use@leeguooooo-plugins\"}]}"] {
            XCTAssertEqual(AgentAccess.codexState(json: json), .unavailable)
        }
    }

    func testInstallationMessageRequiresConfirmedEnabledState() {
        let before = L10n.override
        defer { L10n.override = before }
        L10n.override = .english
        XCTAssertTrue(AgentAccess.installationMessage(.added, label: "Fixture").contains("Fixture"))
        XCTAssertTrue(AgentAccess.installationMessage(.unavailable, label: "Fixture").contains("could not be confirmed"))
        XCTAssertTrue(AgentAccess.installationMessage(.disabled, label: "Fixture").contains("disabled"))
    }
}
