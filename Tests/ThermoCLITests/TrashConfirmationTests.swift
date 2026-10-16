@testable import CleanKit
import AgentCore
@testable import thermo
import XCTest

final class TrashConfirmationTests: XCTestCase {
    func testBatchAppendedWhilePreviewIsPresentedCannotExpandConfirmedRestore() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath().path
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home + "/.Trash", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/Downloads", withIntermediateDirectories: true)
        func entry(_ name: String) throws -> TrashBatch.Entry {
            let destination = home + "/.Trash/" + name
            try Data(name.utf8).write(to: URL(fileURLWithPath: destination))
            return .init(original: home + "/Downloads/" + name, destination: destination, identity: try XCTUnwrap(FileIdentity.of(destination)), bytes: Int64(name.utf8.count))
        }
        let id = UUID().uuidString, a = try entry("a"), b = try entry("b")
        try TrashBatches.append(a, id: id, home: home)
        let command = CleanCommand(app: App(args: try Args(["--yes"])))
        var appended = false; var appendIssue: Error?
        XCTAssertThrowsError(try command.restoreBatch([id], home: home, write: { _ in
            if !appended { appended = true; do { try TrashBatches.append(b, id: id, home: home) } catch { appendIssue = error } }
        }))
        XCTAssertNil(appendIssue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.destination)); XCTAssertTrue(FileManager.default.fileExists(atPath: b.destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.original)); XCTAssertFalse(FileManager.default.fileExists(atPath: b.original))
    }
}
