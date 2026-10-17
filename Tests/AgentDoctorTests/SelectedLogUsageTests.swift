import XCTest
import Darwin
@testable import AgentDoctor

final class SelectedLogUsageTests: XCTestCase {
    let fixture = ToolUsageTests()
    func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func records(_ id: String) throws -> Data {
        try [fixture.call(id, "mcp__fixture__" + id, 1), fixture.output(id, "ok", 2)].reduce(into: Data()) {
            $0.append(try JSONSerialization.data(withJSONObject: $1)); $0.append(10)
        }
    }
    func environment(_ home: URL) -> DoctorEnvironment {
        DoctorEnvironment(home: home, now: fixture.start.addingTimeInterval(100))
    }
    func testSelectedFileReadsBeginningBeyondDefaultTailAndDoesNotScanOtherFiles() throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent(".codex/sessions")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("private-selected-session.jsonl")
        let padding = "{\"type\":\"fixture_padding\",\"padding\":\"" + String(repeating: "x", count: 1000) + "\"}\n"
        var data = try records("early"); data.append(Data(String(repeating: padding, count: 4500).utf8)); data.append(try records("late"))
        try data.write(to: file)
        try records("other").write(to: folder.appendingPathComponent("other.jsonl"))
        let normal = AgentDoctor.usage(since: fixture.start, host: "codex", env: environment(root))
        XCTAssertFalse(normal.tools.contains { $0.name == "early" })
        XCTAssertEqual(normal.coverage.clippedFiles, 1)
        let report = AgentDoctor.usage(since: fixture.start, host: "codex", logFile: file, env: environment(root))
        XCTAssertEqual(Set(report.tools.map(\.name)), Set(["early", "late"]))
        XCTAssertEqual(report.coverage.bytesRead, data.count)
        XCTAssertEqual(report.coverage.filesRead, 1); XCTAssertEqual(report.coverage.filesDiscovered, 1)
        XCTAssertEqual(report.coverage.clippedFiles, 0); XCTAssertTrue(report.complete)
        XCTAssertEqual(report.singleLogFile, true)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("private-selected-session"))
    }
    func testSelectedFileStillHonorsEventWindowAndCancellation() throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("selected.jsonl"); try records("early").write(to: file)
        let outside = AgentDoctor.usage(since: fixture.start.addingTimeInterval(20), host: "codex", logFile: file, env: environment(root))
        XCTAssertTrue(outside.tools.isEmpty); XCTAssertTrue(outside.complete)
        let stopped = AgentDoctor.usage(host: "codex", logFile: file, env: DoctorEnvironment(home: root, cancelled: { true }))
        XCTAssertTrue(stopped.coverage.cancelled); XCTAssertEqual(stopped.coverage.filesRead, 0)
        XCTAssertEqual(stopped.singleLogFile, true)
    }
    func testPipesDirectoriesAndLeafSymlinksCannotBlockOrExpandSelection() throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("regular.jsonl"); try records("early").write(to: file)
        let link = root.appendingPathComponent("link.jsonl"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let fifo = root.appendingPathComponent("pipe.jsonl"); XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        for path in [fifo, root, link] {
            let began = Date()
            let report = AgentDoctor.usage(host: "codex", logFile: path, env: environment(root))
            XCTAssertLessThan(Date().timeIntervalSince(began), 2)
            XCTAssertEqual(report.coverage.unreadableFiles, 1); XCTAssertEqual(report.coverage.filesRead, 0)
            XCTAssertFalse(report.complete); XCTAssertEqual(report.singleLogFile, true)
        }
    }
    func testSingleFileBudgetClipsOnceAndDoesNotReadPast64MiB() throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large.jsonl"); try records("early").write(to: file)
        let writer = try FileHandle(forWritingTo: file)
        try writer.truncate(atOffset: 65 * 1024 * 1024); try writer.seekToEnd()
        try writer.write(contentsOf: records("late")); try writer.close()
        let report = AgentDoctor.usage(since: fixture.start, host: "codex", logFile: file, env: environment(root))
        XCTAssertEqual(report.tools.map(\.name), ["early"])
        XCTAssertEqual(report.coverage.bytesRead, 64 * 1024 * 1024)
        XCTAssertEqual(report.coverage.clippedFiles, 1); XCTAssertTrue(report.coverage.limitReached)
        XCTAssertFalse(report.complete)
    }
    func testSelectionRequiresKnownHostAndLocalURL() throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let noHost = AgentDoctor.usage(logFile: root, env: environment(root))
        XCTAssertTrue(noHost.coverage.limitReached); XCTAssertEqual(noHost.coverage.filesRead, 0)
        let remote = AgentDoctor.usage(host: "codex", logFile: URL(string: "https://example.invalid/log.jsonl")!, env: environment(root))
        XCTAssertEqual(remote.coverage.unreadableFiles, 1); XCTAssertEqual(remote.singleLogFile, true)
    }
}
