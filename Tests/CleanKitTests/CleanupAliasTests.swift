import XCTest
@testable import CleanKit

final class CleanupAliasTests: XCTestCase {
    func testCacheAliasCannotDeleteProtectedDocumentBuildFolder() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let build = home + "/Documents/build"
        let caches = home + "/Library/Caches"
        try FileManager.default.createDirectory(atPath: build, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: caches, withIntermediateDirectories: true)
        let payload = URL(fileURLWithPath: build + "/must-survive")
        try Data("protected fixture".utf8).write(to: payload)
        let alias = caches + "/repository"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: home + "/Documents")
        let item = CleanItem(id: "fixture", category: .system, title: "Fixture", safety: .safe, bytes: 100,
                             paths: [alias + "/build"])
        let result = Cleaner.clean(item, mode: .permanent, guard: Guard(home: home), processTable: ProcessTable(entries: []))
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertFalse(result.failed.isEmpty)
        XCTAssertEqual(try Data(contentsOf: payload), Data("protected fixture".utf8))
    }
    func testAliasDoesNotHideRunningBuildOrExecutable() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home + "/repo/target", withIntermediateDirectories: true)
        let alias = home + "/alias"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: home + "/repo")
        let real = URL(fileURLWithPath: home + "/repo").resolvingSymlinksInPath().path
        let item = CleanItem(id: "project/fixture", category: .projects, title: "Fixture", safety: .review, bytes: 100,
                             paths: [alias + "/target"], group: alias)
        let build = ProcessTable(entries: [.init(pid: 123, name: "cargo", cwd: real)])
        XCTAssertNotNil(Cleaner.refusal(item, mode: .auto, processes: build))
        let executable = ProcessTable(entries: [.init(pid: 123, name: "preview", executable: real + "/target/preview")])
        XCTAssertNotNil(Cleaner.refusal(item, mode: .auto, processes: executable))
    }
}
