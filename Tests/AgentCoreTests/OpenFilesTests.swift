import XCTest
@testable import AgentCore

final class OpenFilesTests: XCTestCase {
    func testFindsAProcessWorkingInsideAFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("openfiles-\(UUID().uuidString)")
        let inner = dir.appendingPathComponent("inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["20"]
        p.currentDirectoryURL = inner
        try p.run()
        defer { p.terminate() }
        Thread.sleep(forTimeInterval: 0.2)

        let started = Date()
        let open = try XCTUnwrap(OpenFiles.current())
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(open.holder(of: dir.path)?.pid, p.processIdentifier)
        XCTAssertEqual(open.holder(of: inner.path)?.name, "sleep")
        // A sibling whose name only starts the same is not inside.
        XCTAssertNil(open.holder(of: dir.path + "-other"))
        XCTAssertNil(open.holder(of: inner.appendingPathComponent("missing").path))
    }

    func testPrefixMatchingStopsAtPathBoundaries() {
        let open = OpenFiles(holders: [.init(path: "/a/b-c/x", pid: 1, name: "one"), .init(path: "/a/b/y", pid: 2, name: "two")])
        XCTAssertEqual(open.holder(of: "/a/b")?.name, "two")
        XCTAssertEqual(open.holder(of: "/a/b-c")?.name, "one")
        XCTAssertNil(open.holder(of: "/a/b/z"))
    }

    func testIdentityChangesWhenAPathIsReplaced() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("identity-\(UUID().uuidString)").path
        FileManager.default.createFile(atPath: file, contents: Data("a".utf8))
        defer { try? FileManager.default.removeItem(atPath: file) }
        let first = try XCTUnwrap(FileIdentity.of(file))
        XCTAssertEqual(FileIdentity.of(file), first)
        try FileManager.default.removeItem(atPath: file)
        FileManager.default.createFile(atPath: file + ".new", contents: Data("b".utf8))
        try FileManager.default.moveItem(atPath: file + ".new", toPath: file)
        XCTAssertNotEqual(FileIdentity.of(file), first)
    }
}
