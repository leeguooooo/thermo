import XCTest
@testable import AgentCore

final class GuardAliasTests: XCTestCase {
    var home = ""
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: home + "/Library/Caches", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/Documents/build", withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: home) }
    func testParentAliasCannotEscapeIntoProtectedDocuments() throws {
        let alias = home + "/Library/Caches/repo"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: home + "/Documents")
        XCTAssertNotNil(Guard(home: home).refusal(alias + "/build"))
    }
    func testParentAliasCannotEscapeHome() throws {
        let alias = home + "/Library/Caches/outside"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: "/Applications")
        XCTAssertNotNil(Guard(home: home).refusal(alias + "/Thermo.app"))
    }
    func testUnlinkingFinalAliasPreservesItsTargetAndRemainsAllowed() throws {
        let alias = home + "/Library/Caches/link"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: home + "/Documents")
        XCTAssertNil(Guard(home: home).refusal(alias))
        XCTAssertEqual(Guard.deletionLocation(alias), URL(fileURLWithPath: alias).deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent("link").path)
    }
    func testAncestorRetargetingIsCheckedOnEveryRefusal() throws {
        let alias = home + "/Library/Caches/repo"
        try FileManager.default.createDirectory(atPath: home + "/project/build", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: home + "/project")
        let guardrail = Guard(home: home)
        XCTAssertNil(guardrail.refusal(alias + "/build"))
        try FileManager.default.removeItem(atPath: alias)
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: home + "/Documents")
        XCTAssertNotNil(guardrail.refusal(alias + "/build"))
    }

    /// Resolving symlinks turns /private/tmp into /tmp; a finished session's scratchpad must still be allowed.
    func testClaudeScratchpadOfASessionIsAllowed() throws {
        let session = "/private/tmp/claude-\(getuid())/-thermo-test-\(UUID().uuidString)/session"
        try FileManager.default.createDirectory(atPath: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: (session as NSString).deletingLastPathComponent) }
        XCTAssertNil(Guard(home: home).refusal(session))
        XCTAssertNotNil(Guard(home: home).refusal("/private/tmp/claude-\(getuid())"))
        XCTAssertNotNil(Guard(home: home).refusal("/private/tmp/other"))
    }
}
