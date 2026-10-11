import XCTest
@testable import CleanKit

final class ProjectHeaderCacheTests: XCTestCase {
    var home = ""
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: home + "/.codex/sessions/2026/10/11", withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: home) }
    func write(_ name: String, cwd: String, time: TimeInterval) throws -> String {
        let path = home + "/.codex/sessions/2026/10/11/" + name + ".jsonl"
        let data = try JSONSerialization.data(withJSONObject: ["payload": ["cwd": cwd]])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: time)], ofItemAtPath: path)
        return path
    }
    func testUnchangedHeadersAreNotReopenedAndChangedFilesRefresh() throws {
        _ = try write("old", cwd: home + "/project", time: 100)
        let newer = try write("new", cwd: home + "/project", time: 200)
        var reads = 0
        let reader: (String) -> String? = { reads += 1; return AISessions.codexMeta($0).cwd }
        var first = ProjectSignals()
        ProjectSignals.codex(home: home, into: &first, readCWD: reader)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(first.uses[home + "/project"]?.date, Date(timeIntervalSince1970: 200))
        var second = ProjectSignals()
        ProjectSignals.codex(home: home, into: &second, readCWD: reader)
        XCTAssertEqual(reads, 2, "unchanged transcripts must not be opened again")
        XCTAssertEqual(first.uses, second.uses)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 300)], ofItemAtPath: newer)
        var third = ProjectSignals()
        ProjectSignals.codex(home: home, into: &third, readCWD: reader)
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(third.uses[home + "/project"]?.date, Date(timeIntervalSince1970: 300))
    }
    func testReplacementWithSameMtimeAndDeletionDoNotReuseOldCWD() throws {
        let path = try write("one", cwd: home + "/first", time: 100)
        var first = ProjectSignals()
        ProjectSignals.codex(home: home, into: &first)
        _ = try write("one", cwd: home + "/other", time: 100)
        var replaced = ProjectSignals()
        ProjectSignals.codex(home: home, into: &replaced)
        XCTAssertNil(replaced.uses[home + "/first"])
        XCTAssertNotNil(replaced.uses[home + "/other"])
        try FileManager.default.removeItem(atPath: path)
        var deleted = ProjectSignals()
        ProjectSignals.codex(home: home, into: &deleted)
        XCTAssertTrue(deleted.uses.isEmpty)
    }
    func testSameInodeChangeWithinOneSecondIsReadAgain() throws {
        let path = try write("one", cwd: home + "/first", time: 100)
        var first = ProjectSignals()
        ProjectSignals.codex(home: home, into: &first)
        let inode = try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? NSNumber
        let data = try JSONSerialization.data(withJSONObject: ["payload": ["cwd": home + "/other"]])
        try data.write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100.25)], ofItemAtPath: path)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? NSNumber, inode)
        var changed = ProjectSignals()
        ProjectSignals.codex(home: home, into: &changed)
        XCTAssertNil(changed.uses[home + "/first"])
        XCTAssertEqual(changed.uses[home + "/other"]?.date, Date(timeIntervalSince1970: 100.25))
    }

    func testCancellationKeepsPreviousHeaderIndex() throws {
        _ = try write("one", cwd: home + "/first", time: 100)
        _ = try write("two", cwd: home + "/other", time: 100)
        var first = ProjectSignals()
        ProjectSignals.codex(home: home, into: &first)
        let url = URL(fileURLWithPath: home + "/Library/Caches/dev.thermo/codex-project-headers.json")
        let before = try Data(contentsOf: url)
        _ = try write("one", cwd: home + "/first", time: 200)
        _ = try write("two", cwd: home + "/other", time: 200)
        let token = ScanCancellation()
        ScanCancellation.current = token
        defer { ScanCancellation.current = nil }
        var reads = 0
        var cancelled = ProjectSignals()
        ProjectSignals.codex(home: home, into: &cancelled, readCWD: { path in
            reads += 1; token.cancel(); return AISessions.codexMeta(path).cwd
        })
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(try Data(contentsOf: url), before, "partial activity cannot replace the complete header index")
    }

    func testCorruptCacheFallsBackToCurrentHeaders() throws {
        _ = try write("one", cwd: home + "/project", time: 100)
        let cache = home + "/Library/Caches/dev.thermo/codex-project-headers.json"
        try FileManager.default.createDirectory(atPath: (cache as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data("corrupt".utf8).write(to: URL(fileURLWithPath: cache))
        var signals = ProjectSignals()
        ProjectSignals.codex(home: home, into: &signals)
        XCTAssertNotNil(signals.uses[home + "/project"])
        let cached = try Data(contentsOf: URL(fileURLWithPath: cache))
        XCTAssertNotNil(try? JSONDecoder().decode(ProjectSignals.HeaderCache.self, from: cached))
        XCTAssertFalse(String(decoding: cached, as: UTF8.self).contains("payload"))
    }
}
