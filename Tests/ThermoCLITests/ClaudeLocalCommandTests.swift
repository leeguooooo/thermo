import XCTest
@testable import thermo

final class ClaudeLocalCommandTests: XCTestCase {
    func testReadOnlyCommandHasScopedHelpAndRejectsMutationOptions() throws {
        XCTAssertTrue(CommandHelp.text(for: ["agents", "claude-local"]).contains("agents claude-local [--json]"))
        XCTAssertNoThrow(try CommandContract.validate(Args(["agents", "claude-local", "--json"])))
        for flag in ["--yes", "--dry-run", "--csv", "--all", "--probe"] {
            XCTAssertThrowsError(try CommandContract.validate(Args(["agents", "claude-local", flag])), flag)
        }
        let capability = try XCTUnwrap(CommandHelp.capabilities.first { $0.command == "agents claude-local" })
        XCTAssertEqual(capability.execution, "read-only-local-diagnostics")
        XCTAssertFalse(capability.supportsDryRun)
        XCTAssertEqual(capability.structuredFormats, ["json"])
    }
}
