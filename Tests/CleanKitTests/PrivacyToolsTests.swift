import XCTest
@testable import CleanKit

final class PrivacyToolsTests: XCTestCase {
    private var home: URL!
    override func setUpWithError() throws {
        L10n.override = .english
        home = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-privacy-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { L10n.override = nil; try FileManager.default.removeItem(at: home) }
    private func file(_ suffix: String, _ content: String) throws -> URL {
        let url = home.appendingPathComponent("Library/Application Support/" + suffix)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        return url
    }
    private var quiet: PrivacyToolsService { .init(home: home, runner: { _, _ in .init(status: 0, output: "/sbin/launchd\n") }) }
    func testSettingsPreserveOtherPreferencesAndRestoreInReverseOrder() throws {
        let url = try file("Google/Chrome/Default/Preferences", "{\"keep\":42,\"profile\":{\"keep\":true}}")
        let original = try Data(contentsOf: url)
        _ = try quiet.applyBrowser(.location)
        let location = try Data(contentsOf: url)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: location) as? [String: Any])
        XCTAssertEqual(object["keep"] as? Int, 42)
        let profile = try XCTUnwrap(object["profile"] as? [String: Any])
        XCTAssertEqual(profile["keep"] as? Bool, true)
        XCTAssertEqual((profile["default_content_setting_values"] as? [String: Any])?["geolocation"] as? Int, 2)
        _ = try quiet.applyBrowser(.webRTC)
        object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual((object["webrtc"] as? [String: Any])?["ip_handling_policy"] as? String, "disable_non_proxied_udp")
        _ = try quiet.restoreLatestBrowserChange()
        XCTAssertEqual(try Data(contentsOf: url), location)
        _ = try quiet.restoreLatestBrowserChange()
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    func testRestoreRefusesToOverwriteExternalChanges() throws {
        let url = try file("Microsoft Edge/Default/Preferences", "{}")
        _ = try quiet.applyBrowser(.location)
        try Data("{\"external\":1}".utf8).write(to: url)
        XCTAssertThrowsError(try quiet.restoreLatestBrowserChange())
        XCTAssertEqual(try String(contentsOf: url), "{\"external\":1}")
    }
    func testFirefoxDisablesBothRuntimeAndStartupPreferenceAndRestoresAbsentUserJS() throws {
        let prefs = try file("Firefox/Profiles/a.default/prefs.js", "user_pref(\"keep\", true);\nuser_pref(\"geo.enabled\", true);\n")
        let original = try Data(contentsOf: prefs)
        let user = prefs.deletingLastPathComponent().appendingPathComponent("user.js")
        _ = try quiet.applyBrowser(.location)
        XCTAssertTrue(try String(contentsOf: prefs).contains("user_pref(\"geo.enabled\", false);"))
        XCTAssertTrue(try String(contentsOf: user).contains("user_pref(\"geo.enabled\", false);"))
        _ = try quiet.restoreLatestBrowserChange()
        XCTAssertEqual(try Data(contentsOf: prefs), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: user.path))
    }
    func testRunningBrowserBlocksWritesAndDoesNotCloseIt() throws {
        let url = try file("BraveSoftware/Brave-Browser/Default/Preferences", "{}")
        let service = PrivacyToolsService(home: home, runner: { executable, args in
            XCTAssertEqual(executable, "/bin/ps"); XCTAssertEqual(args, ["-axo", "comm="])
            return .init(status: 0, output: "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser\n")
        })
        XCTAssertThrowsError(try service.applyBrowser(.location))
        XCTAssertEqual(try String(contentsOf: url), "{}")
    }
    func testRenamedBrowserBundleStillBlocksWrites() throws {
        _ = try file("Google/Chrome/Default/Preferences", "{}")
        let service = PrivacyToolsService(home: home, runner: { _, _ in .init(status: 0, output: "/Applications/Renamed.app/Contents/MacOS/Google Chrome\n") })
        XCTAssertThrowsError(try service.applyBrowser(.location))
    }
    func testEmptyProcessInspectionFailsClosed() throws {
        let service = PrivacyToolsService(home: home, runner: { _, _ in .init(status: 0) })
        XCTAssertThrowsError(try service.requireBrowsersClosed())
    }
    func testUnrelatedChromiumRootSymlinkDoesNotBlockProfileDiscovery() throws {
        _ = try file("Google/Chrome/Default/Preferences", "{}")
        let root = home.appendingPathComponent("Library/Application Support/Google/Chrome")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("RunningChromeVersion").path, withDestinationPath: "999.0.0")
        let profiles = try quiet.discoverProfiles()
        XCTAssertEqual(profiles.map(\.name), ["Chrome · Default"])
        _ = try quiet.applyBrowser(.location)
    }
    func testSymlinkProfileIsRejected() throws {
        let actual = try file("actual/Preferences", "{}")
        let root = home.appendingPathComponent("Library/Application Support/Google/Chrome")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Default"), withDestinationURL: actual.deletingLastPathComponent())
        XCTAssertThrowsError(try quiet.applyBrowser(.location))
        XCTAssertEqual(try String(contentsOf: actual), "{}")
    }
    func testTimezoneRejectsShellSyntaxAndInvalidIdentifiers() {
        XCTAssertTrue(PrivacyToolsService.validTimezone("Asia/Tokyo"))
        for value in ["Asia/Tokyo'; touch /tmp/x", "$(id)", "America/NoSuchZone", "../../etc/passwd", ""] {
            XCTAssertFalse(PrivacyToolsService.validTimezone(value))
            XCTAssertThrowsError(try quiet.setTimezone(value))
        }
    }
    func testMailCookieDeletionOnlyMatchesExactDomainAndSubdomains() throws {
        let database = try file("Google/Chrome/Default/Network/Cookies", "")
        _ = try file("Google/Chrome/Default/Preferences", "{}")
        _ = try PrivacyToolsService.command("/usr/bin/sqlite3", [database.path, "CREATE TABLE cookies(host_key TEXT); INSERT INTO cookies VALUES('mail.com'),('.mail.com'),('login.mail.com'),('notmail.com'),('mail.com.evil.test'),('example.test');"])
        let service = PrivacyToolsService(home: home, runner: { executable, args in
            if executable == "/bin/ps" { return .init(status: 0, output: "/sbin/launchd\n") }
            XCTAssertEqual(executable, "/usr/bin/sqlite3")
            return try PrivacyToolsService.command(executable, args)
        })
        let report = try service.clearMailCookies()
        XCTAssertTrue(report.hasPrefix("Deleted 3 mail.com cookies."), report)
        let remaining = try PrivacyToolsService.command("/usr/bin/sqlite3", [database.path, "SELECT host_key FROM cookies ORDER BY host_key;"])
        XCTAssertEqual(remaining.output, "example.test\nmail.com.evil.test\nnotmail.com\n")
        let backups = home.appendingPathComponent("Library/Application Support/Thermo/PrivacyBackups")
        let saved = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil).filter { $0.pathExtension == "sqlite" }
        XCTAssertEqual(saved.count, 1)
        let manifest = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: saved[0].appendingPathExtension("json")))
        XCTAssertEqual(URL(fileURLWithPath: try XCTUnwrap(manifest["sourceDatabase"])).resolvingSymlinksInPath().path, database.resolvingSymlinksInPath().path)
        XCTAssertEqual(manifest["browser"], "Chrome")
        XCTAssertEqual(manifest["backupSHA256"]?.count, 64)
        XCTAssertEqual(try PrivacyToolsService.command("/usr/bin/sqlite3", [saved[0].path, "SELECT count(*) FROM cookies;"]).output, "6\n")
    }
    func testPreferenceEditedAfterPlanningIsNotOverwritten() throws {
        final class Counter: @unchecked Sendable { var value = 0 }
        let counter = Counter()
        let url = try file("Google/Chrome/Default/Preferences", "{}")
        let service = PrivacyToolsService(home: home, runner: { _, _ in
            counter.value += 1
            if counter.value == 2 { try Data("{\"external\":true}".utf8).write(to: url) }
            return .init(status: 0, output: "/sbin/launchd\n")
        })
        XCTAssertThrowsError(try service.applyBrowser(.location))
        XCTAssertEqual(try String(contentsOf: url), "{\"external\":true}")
    }
    func testForgedBackupCannotRestoreAnUnrelatedHomeFile() throws {
        let url = try file("Google/Chrome/Default/Preferences", "{}")
        _ = try quiet.applyBrowser(.location)
        let storage = home.appendingPathComponent("Library/Application Support/Thermo/PrivacyBackups")
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil).first)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: backup)) as? [String: Any])
        var entries = try XCTUnwrap(json["files"] as? [[String: Any]])
        entries[0]["path"] = home.appendingPathComponent("unrelated.txt").path
        json["files"] = entries
        try JSONSerialization.data(withJSONObject: json).write(to: backup)
        XCTAssertThrowsError(try quiet.restoreLatestBrowserChange())
        XCTAssertTrue(try String(contentsOf: url).contains("geolocation"))
    }
    func testEnvironmentPartialFailureListsSuccessfulAndFailedNames() throws {
        let service = PrivacyToolsService(home: home, runner: { _, args in
            .init(status: args[1] == "ANTHROPIC_API_KEY" ? 1 : 0)
        })
        let result = try service.clearClaudeEnvironment()
        XCTAssertTrue(result.hasPrefix("Removed 13 Claude variable names"), result)
        XCTAssertTrue(result.contains("Failed variable names: ANTHROPIC_API_KEY"), result)
        XCTAssertTrue(result.contains("Successful variable names: ANTHROPIC_AUTH_TOKEN"), result)
    }
    func testClaudeEnvironmentOnlyUnsetsNamedVariablesWithoutReadingValues() throws {
        let service = PrivacyToolsService(home: home, runner: { executable, args in
            XCTAssertEqual(executable, "/bin/launchctl")
            XCTAssertEqual(args.first, "unsetenv")
            XCTAssertTrue(args[1].hasPrefix("CLAUDE_") || args[1].hasPrefix("ANTHROPIC_"))
            XCTAssertEqual(args.count, 2)
            return .init(status: 0, output: "/sbin/launchd\n")
        })
        _ = try service.clearClaudeEnvironment()
    }
}
