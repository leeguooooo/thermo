import XCTest
@testable import AgentDoctor

final class ClaudeProfilesTests: XCTestCase {
    func fixture(_ body: (URL, ClaudeProfiles) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("claude-profiles-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try body(home, ClaudeProfiles(home: home, keychainHasItem: { $0 == "Claude Code-credentials" }, alive: { $0 == 42 }))
    }
    func write(_ home: URL, _ path: String, _ text: String = "{}") throws {
        let file = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func testToolFoldersSharingThePrefixAreNotProfiles() throws {
        try fixture { home, profiles in
            try write(home, ".claude-code-router/config.json")
            try write(home, ".claude-statusbar-last-check", "1")
            try write(home, ".claude-work/.claude.json")
            try write(home, ".claude-side/projects/a/b.jsonl")
            XCTAssertEqual(profiles.list().map(\.name), ["default", "side", "work"])
        }
    }

    func testAccountFileSitsBesideDefaultFolderAndInsideOthers() throws {
        try fixture { home, profiles in
            try write(home, ".claude.json", #"{"oauthAccount":{"emailAddress":"a@b.c","organizationName":"Org","billingType":"stripe"}}"#)
            try write(home, ".claude-work/.claude.json", #"{"oauthAccount":{"emailAddress":"w@b.c"}}"#)
            let list = profiles.list()
            XCTAssertEqual(list[0].email, "a@b.c")
            XCTAssertEqual(list[0].organization, "Org")
            XCTAssertEqual(list[0].signedIn, true)
            XCTAssertEqual(list[1].email, "w@b.c")
            XCTAssertEqual(list[1].signedIn, false)
        }
    }

    func testCreateMakesAPrivateListedFolderAndRefusesCollisions() throws {
        try fixture { home, profiles in
            try profiles.create(name: "work")
            let path = home.appendingPathComponent(".claude-work").path
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path))[.posixPermissions] as? Int, 0o700)
            XCTAssertEqual(profiles.list().map(\.name), ["default", "work"])
            XCTAssertThrowsError(try profiles.create(name: "work")) { XCTAssertEqual($0 as? ClaudeProfileError, .exists) }
            for bad in ["", "../x", "A", "a b", "-a"] {
                XCTAssertThrowsError(try profiles.create(name: bad)) { XCTAssertEqual($0 as? ClaudeProfileError, .invalidName) }
            }
        }
    }

    func testLiveSessionsCountOnlyRunningProcesses() throws {
        try fixture { home, profiles in
            try write(home, ".claude-work/.claude.json")
            try write(home, ".claude-work/sessions/42.json")
            try write(home, ".claude-work/sessions/43.json")
            XCTAssertEqual(profiles.list()[1].liveSessions, 1)
        }
    }

    func testLaunchCommandQuotesFolderAndClearsOverrides() {
        let profile = ClaudeProfile(name: "x", directory: "/Users/a b/.claude-x", isDefault: false, signedIn: nil, liveSessions: 0)
        XCTAssertTrue(profile.launchCommand.contains("CLAUDE_CONFIG_DIR='/Users/a b/.claude-x' claude"))
        XCTAssertTrue(profile.launchCommand.contains("-u ANTHROPIC_API_KEY"))
    }

    func testKeychainServiceMatchesClaudeCodeNaming() {
        XCTAssertEqual(ClaudeProfiles.keychainService(directory: "/x", isDefault: true), "Claude Code-credentials")
        let digest = ClaudeProfiles.keychainService(directory: "/x", isDefault: false)
        XCTAssertTrue(digest.hasPrefix("Claude Code-credentials-"))
        XCTAssertEqual(digest.count, "Claude Code-credentials-".count + 8)
    }
}
