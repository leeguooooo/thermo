import XCTest
@testable import CleanKit

final class CleanupRuntimeGuardTests: XCTestCase {
    func testAppStartedAfterScanPreventsCacheDeletion() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/Library/Developer/Xcode/DerivedData/fixture"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: URL(fileURLWithPath: path + "/file"))
        let item = CleanItem(id: "xcode-derived-data", category: .xcode, title: "Fixture", safety: .safe, bytes: 100,
                             paths: [path]) // the old scan saw no running Xcode
        let processes = ProcessTable(entries: [.init(pid: 123, name: "Xcode")])
        let result = Cleaner.clean(item, guard: Guard(home: home), processTable: processes)
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertFalse(result.failed.isEmpty)
        XCTAssertTrue(FS.exists(path + "/file"))
    }
    func testKnownQuitAppBlockClearsAfterExitButOtherBlocksRemain() {
        L10n.override = .english
        defer { L10n.override = nil }
        var item = CleanItem(id: "xcode-derived-data", category: .xcode, title: "Fixture", safety: .safe,
                             bytes: 100, paths: ["/fixture"], blocked: "quit Xcode first")
        XCTAssertNil(Cleaner.refusal(item, mode: .auto, processes: ProcessTable(entries: [])))
        item.blocked = "unknown permission state"
        XCTAssertEqual(Cleaner.refusal(item, mode: .auto, processes: ProcessTable(entries: [])), "unknown permission state")
    }

    func testResumedAgentSessionIsPreservedFromOldReport() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/.codex/sessions/rollout-synthetic-session.jsonl"
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: URL(fileURLWithPath: path))
        let item = CleanItem(id: "codex-sessions/fixture", category: .aiSessions, title: "Fixture", safety: .review,
                             bytes: 100, paths: [path])
        let resumed = ProcessTable(entries: [.init(pid: 123, name: "codex", argv: ["codex", "resume", "synthetic-session"])])
        let result = Cleaner.clean(item, mode: .permanent, guard: Guard(home: home), processTable: resumed)
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertFalse(result.failed.isEmpty)
        XCTAssertTrue(FS.exists(path))
    }

    func testProjectAgentBlockCanClearWhenTheAgentExits() {
        L10n.override = .english
        defer { L10n.override = nil }
        let item = CleanItem(id: "project/fixture", category: .projects, title: "Fixture", safety: .review, bytes: 100,
                             paths: ["/fixture/repo/target"], blocked: "an agent is running in it", group: "/fixture/repo")
        XCTAssertNil(Cleaner.refusal(item, mode: .auto, processes: ProcessTable(entries: [])))
        let active = ProcessTable(entries: [.init(pid: 123, name: "codex", cwd: "/fixture/repo")])
        XCTAssertNotNil(Cleaner.refusal(item, mode: .auto, processes: active))
    }

    func testBuildAndExecutableProtectProjectOutput() {
        let item = CleanItem(id: "project/fixture", category: .projects, title: "Target", safety: .review, bytes: 100,
                             paths: ["/fixture/repo/target"], group: "/fixture/repo")
        let build = ProcessTable(entries: [.init(pid: 123, name: "cargo", cwd: "/fixture/repo")])
        XCTAssertNotNil(Cleaner.refusal(item, mode: .auto, processes: build))
        let live = ProcessTable(entries: [.init(pid: 123, name: "preview", executable: "/fixture/repo/target/debug/preview")])
        XCTAssertNotNil(Cleaner.refusal(item, mode: .auto, processes: live))
        let unrelated = ProcessTable(entries: [.init(pid: 123, name: "cargo", cwd: "/fixture/repository")])
        XCTAssertNil(Cleaner.refusal(item, mode: .auto, processes: unrelated))
    }
    func testTrashOnlyNeverExecutesToolCommandAndAutoDoesNotClaimTrash() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let sentinel = home + "/must-not-exist"
        let forbidden = CleanItem(id: "fixture", category: .xcode, title: "Fixture", safety: .review, bytes: 100,
                                  commands: [["/usr/bin/touch", sentinel]])
        let result = Cleaner.clean(forbidden, mode: .trash, guard: Guard(home: home), processTable: ProcessTable(entries: []))
        XCTAssertFalse(FS.exists(sentinel))
        XCTAssertFalse(result.failed.isEmpty)
        let harmless = CleanItem(id: "fixture", category: .xcode, title: "Fixture", safety: .review, bytes: 100,
                                 commands: [["/usr/bin/true"]])
        let completed = Cleaner.clean(harmless, guard: Guard(home: home), processTable: ProcessTable(entries: []))
        XCTAssertTrue(completed.failed.isEmpty)
        XCTAssertFalse(completed.trashed, "tool-managed deletion cannot be reported as recoverable in Trash")
    }
}
