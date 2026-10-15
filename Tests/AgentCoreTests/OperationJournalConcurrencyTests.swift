import XCTest
import Foundation
import Darwin
@testable import AgentCore

final class OperationJournalConcurrencyTests: XCTestCase {
    static let driver: Result<URL, Error> = Result {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-journal-worker-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("main.swift")
        try FileManager.default.copyItem(at: repo.appendingPathComponent("Tests/Fixtures/JournalConcurrencyWorker.swift"), to: source)
        let binary = root.appendingPathComponent("writer")
        let result = CommandRunner.run("/usr/bin/xcrun", arguments: ["swiftc", repo.appendingPathComponent("Sources/AgentCore/OperationJournal.swift").path, source.path, "-o", binary.path], timeout: 30)
        guard result.status == 0 else { throw NSError(domain: "JournalWorker", code: 1, userInfo: [NSLocalizedDescriptionKey: result.output]) }
        return binary
    }
    override class func tearDown() {
        if case .success(let binary) = driver { try? FileManager.default.removeItem(at: binary.deletingLastPathComponent()) }
        super.tearDown()
    }
    var home = ""
    var children: [Process] = []
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-journal-processes-" + UUID().uuidString).path
        try FileManager.default.createDirectory(at: OperationJournal.url(home: home).deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    override func tearDown() {
        children.filter(\.isRunning).forEach { $0.terminate() }
        children.forEach { $0.waitUntilExit() }
        try? FileManager.default.removeItem(atPath: home)
    }
    func spawn(_ mode: String = "append", worker: String, count: Int) throws -> Process {
        let process = Process(); process.executableURL = try Self.driver.get()
        process.arguments = [mode, home, worker, String(count)]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); children.append(process); return process
    }
    func ready(_ workers: [String]) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if workers.allSatisfy({ FileManager.default.fileExists(atPath: home + "/ready-" + $0) }) { return true }
            usleep(1000)
        }
        return false
    }
    func finish(_ process: Process) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline { usleep(1000) }
        return !process.isRunning
    }

    func testConcurrentProcessesRotateWithoutLosingOrCorruptingRecords() throws {
        OperationJournal.record(.init(id: "seed", feature: "qa", action: "seed", items: [.init(target: String(repeating: "x", count: OperationJournal.maxBytes - 400), status: "done")]), home: home)
        let workers = (0..<12).map(String.init)
        for worker in workers { _ = try spawn(worker: worker, count: 30) }
        XCTAssertTrue(ready(workers))
        try Data().write(to: URL(fileURLWithPath: home + "/gate"))
        for process in children { XCTAssertTrue(finish(process)); if !process.isRunning { XCTAssertEqual(process.terminationStatus, 0) } }
        let report = OperationJournal.readReport(home: home)
        let expected = Set(["seed"] + workers.flatMap { worker in (0..<30).map { "\(worker)-\($0)" } })
        XCTAssertTrue(report.complete, report.issues.joined(separator: "\n"))
        XCTAssertEqual(Set(report.records.map(\.id)), expected)
        let folder = OperationJournal.url(home: home).deletingLastPathComponent()
        let lines = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }.reduce(0) { count, file in count + ((try? Data(contentsOf: file).split(separator: 10).count) ?? 0) }
        XCTAssertEqual(lines, expected.count, "do not hide duplicate rows through ID deduplication")
        XCTAssertTrue(FileManager.default.fileExists(atPath: OperationJournal.url(home: home).deletingLastPathComponent().appendingPathComponent("operations.1.jsonl").path))
    }

    func testReaderReportsBusyAndProcessDeathReleasesTheWaitingWriter() throws {
        OperationJournal.record(.init(id: "seed", feature: "qa", action: "seed", items: [.init(target: "owned", status: "done")]), home: home)
        let holder = try spawn("hold", worker: "holder", count: 0)
        XCTAssertTrue(ready(["holder"]))
        let before = try Data(contentsOf: OperationJournal.url(home: home))
        let report = OperationJournal.readReport(home: home)
        XCTAssertFalse(report.complete); XCTAssertTrue(report.issues.joined().contains("busy"))
        try Data().write(to: URL(fileURLWithPath: home + "/gate"))
        let writer = try spawn(worker: "after", count: 1)
        XCTAssertTrue(ready(["after"]))
        usleep(50000)
        XCTAssertTrue(writer.isRunning)
        XCTAssertEqual(try Data(contentsOf: OperationJournal.url(home: home)), before)
        holder.terminate(); XCTAssertTrue(finish(holder))
        XCTAssertTrue(finish(writer)); if !writer.isRunning { XCTAssertEqual(writer.terminationStatus, 0) }
        XCTAssertEqual(Set(OperationJournal.read(home: home).map(\.id)), ["seed", "after-0"])
    }
}
