import Combine
import XCTest
@testable import ThermoApp

final class AgentAccessStateTests: XCTestCase {
    @MainActor func testOpeningSheetDuringCheckDoesNotStartAnotherQuery() async {
        let access = AgentAccess()
        let release = DispatchSemaphore(value: 0)
        let done = expectation(description: "original status is accepted")
        let subscription = access.$codex.sink { if $0 == .added { done.fulfill() } }
        defer { subscription.cancel() }
        access.refresh(check: {
            _ = release.wait(timeout: .now() + 2)
            return .init(cliLinked: true, claude: .missing, codex: .added)
        })
        access.refresh()
        access.refresh()
        release.signal()
        await fulfillment(of: [done], timeout: 2)
        XCTAssertFalse(access.checking)
        XCTAssertTrue(access.ready)
    }

    @MainActor func testRepeatedRefreshesKeepOnlyTheLatestFollowUp() async {
        let access = AgentAccess()
        let release = DispatchSemaphore(value: 0)
        let done = expectation(description: "latest status appears")
        let obsolete = expectation(description: "superseded check never runs")
        obsolete.isInverted = true
        let subscription = access.$codex.sink { if $0 == .added { done.fulfill() } }
        defer { subscription.cancel() }
        access.refresh(check: {
            _ = release.wait(timeout: .now() + 2)
            return .init(cliLinked: false, claude: .missing, codex: .missing)
        })
        access.refresh(check: {
            obsolete.fulfill()
            return .init(cliLinked: false, claude: .missing, codex: .notAdded)
        })
        access.refresh(check: { .init(cliLinked: true, claude: .missing, codex: .added) })
        XCTAssertTrue(access.checking)
        XCTAssertFalse(access.ready)
        release.signal()
        await fulfillment(of: [done, obsolete], timeout: 0.4)
        XCTAssertFalse(access.checking)
        XCTAssertTrue(access.ready)
    }

    @MainActor func testFailedCheckIsNotMissingOrReady() async {
        let access = AgentAccess()
        let done = expectation(description: "unavailable status")
        let subscription = access.$codex.sink { if $0 == .unavailable { done.fulfill() } }
        defer { subscription.cancel() }
        access.refresh(check: { .init(cliLinked: true, claude: .missing, codex: .unavailable) })
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(access.codex, .unavailable)
        XCTAssertFalse(access.ready)
    }

    func testMalformedClaudeManifestIsNotTreatedAsMissingPlugin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let plugins = root.appendingPathComponent(".claude/plugins")
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(AgentAccess.claudeState(home: root.path), .notAdded)
        try Data("invalid fixture".utf8).write(to: plugins.appendingPathComponent("installed_plugins.json"))
        XCTAssertEqual(AgentAccess.claudeState(home: root.path), .unavailable)
        try Data("{\"plugins\":{}}".utf8).write(to: plugins.appendingPathComponent("installed_plugins.json"))
        XCTAssertEqual(AgentAccess.claudeState(home: root.path), .notAdded)
    }
}
