import XCTest
@testable import CleanKit

final class ScanNarrowingTests: XCTestCase {
    let rules = Set(Rules.paths.map(\.id))

    func testItemIDsSkipTheProjectAndAppDataWalks() {
        for id in ["claude-scratchpads", "claude-plugin-old-versions", "chrome-cache", "pnpm-store-prune"] {
            XCTAssertFalse(DiskScanner.step("projects", ruleIDs: rules, mayProduce: id), id)
            XCTAssertFalse(DiskScanner.step("app data", ruleIDs: rules, mayProduce: id), id)
        }
        XCTAssertTrue(DiskScanner.step("AI tools", ruleIDs: rules, mayProduce: "claude-scratchpads"))
        XCTAssertTrue(DiskScanner.step("tools", ruleIDs: rules, mayProduce: "pnpm-store-prune"))
    }

    func testGroupSelectorsAndStructuredIDsKeepTheirStep() {
        XCTAssertTrue(DiskScanner.step("AI sessions", ruleIDs: rules, mayProduce: "codex-sessions"))
        XCTAssertTrue(DiskScanner.step("AI sessions", ruleIDs: rules, mayProduce: "codex-sessions/tk.com-piggo"))
        XCTAssertTrue(DiskScanner.step("projects", ruleIDs: rules, mayProduce: "project/github.com-thermo-.build"))
        XCTAssertTrue(DiskScanner.step("projects", ruleIDs: rules, mayProduce: "worktree"))
        XCTAssertTrue(DiskScanner.step("app data", ruleIDs: rules, mayProduce: "app-data/lark"))
        XCTAssertTrue(DiskScanner.step("simulators", ruleIDs: rules, mayProduce: "simulator-unavailable"))
    }

    func testPathRulesRunOnlyForTheirOwnID() throws {
        let rule = try XCTUnwrap(Rules.paths.first { !$0.paths.isEmpty })
        XCTAssertTrue(DiskScanner.step(rule.title, ruleIDs: rules, mayProduce: rule.id))
        XCTAssertFalse(DiskScanner.step(rule.title, ruleIDs: rules, mayProduce: "claude-scratchpads") && rule.id != "claude-scratchpads")
        XCTAssertTrue(DiskScanner.step("a step added later", ruleIDs: rules, mayProduce: "anything"))
    }
}
