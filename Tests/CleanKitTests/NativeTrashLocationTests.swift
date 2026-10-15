import XCTest
import AgentCore
import Darwin
@testable import CleanKit

final class NativeTrashLocationTests: XCTestCase {
    func entry(_ destination: String, original: String = "/state/Applications/Fixture.app") -> TrashBatch.Entry {
        .init(original: original, destination: destination, identity: "fixture", bytes: 1)
    }
    func testNativeLocationMustComeFromOSLookupForTheOriginalParent() {
        let item = entry("/native/.Trash/Fixture.app")
        let root = TrashBatches.trashDirectory(item, home: "/state", currentHome: "/state", nativeTrash: { parent in
            XCTAssertEqual(parent, "/state/Applications")
            return "/native/.Trash"
        })
        XCTAssertEqual(root, "/native/.Trash")
        XCTAssertNil(TrashBatches.trashDirectory(entry("/native/.Trash/nested/Fixture.app"), home: "/state", currentHome: "/state", nativeTrash: { _ in "/native/.Trash" }))
        XCTAssertNil(TrashBatches.trashDirectory(item, home: "/state", currentHome: "/state", nativeTrash: { _ in "/different/.Trash" }))
    }
    func testAnExplicitDifferentHomeCannotExpandIntoTheCurrentUsersNativeTrash() {
        XCTAssertNil(TrashBatches.trashDirectory(entry("/native/.Trash/Fixture.app"), home: "/other", currentHome: "/current", nativeTrash: { _ in
            XCTFail("must not ask for another user's native trash"); return "/native/.Trash"
        }))
        XCTAssertEqual(TrashBatches.trashDirectory(entry("/other/.Trash/Fixture.app"), home: "/other", currentHome: "/current", nativeTrash: { _ in
            XCTFail("logical home remains the fixture boundary"); return "/native/.Trash"
        }), "/other/.Trash")
    }
    func testUnknownNativeLocationAndUnsafeOriginalPathsFailClosed() {
        for original in ["relative/Fixture.app", "/state/../Applications/Fixture.app", "/state/./Fixture.app"] {
            XCTAssertNil(TrashBatches.trashDirectory(entry("/native/.Trash/Fixture.app", original: original), home: "/state", currentHome: "/state", nativeTrash: { _ in
                XCTFail("unsafe original must not be queried"); return "/native/.Trash"
            }))
        }
        XCTAssertNil(TrashBatches.trashDirectory(entry("/native/.Trash/Fixture.app"), home: "/state", currentHome: "/state", nativeTrash: { _ in throw NSError(domain: "fixture", code: 1) }))
    }

    func testSystemPrivateVarAliasCanRestoreButUserSymlinkCannot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).standardizedFileURL
        let home = root.path
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = root.appendingPathComponent(".Trash"), parent = root.appendingPathComponent("Original")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let destination = trash.appendingPathComponent("fixture")
        let bytes = Data("owned alias fixture".utf8); try bytes.write(to: destination)
        func privateAlias(_ path: String) -> String { path.hasPrefix("/var/") ? "/private" + path : path }
        let original = parent.appendingPathComponent("fixture").path
        let item = TrashBatch.Entry(original: privateAlias(original), destination: privateAlias(destination.path), identity: try XCTUnwrap(FileIdentity.of(destination.path)), bytes: Int64(bytes.count))
        let id = UUID().uuidString
        try TrashBatches.append(item, id: id, home: home)
        let restored = try TrashBatches.restore(id: id, home: home)
        XCTAssertEqual(restored.items.first?.status, "restored")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: original)), bytes)
        try FileManager.default.moveItem(atPath: original, toPath: destination.path)
        let alias = root.appendingPathComponent("UserLink")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: trash)
        var linked = try TrashBatches.load(id, home: home).entries[0]
        linked.destination = alias.appendingPathComponent("fixture").path
        XCTAssertNotNil(TrashBatches.refusal(linked, home: home))
    }

    func testDestinationDotSegmentsCannotBecomeAnAllowedTrashRoot() {
        for destination in ["/state/.Trash/../.Trash/fixture", "/state/.Trash/./fixture", "relative/.Trash/fixture"] {
            XCTAssertNil(TrashBatches.trashDirectory(entry(destination), home: "/state", currentHome: "/state", nativeTrash: { _ in "/state/.Trash" }))
        }
    }

    func testRestoreWalkNeedsSearchPermissionRatherThanListingPermissionOnAncestors() throws {
        guard getuid() != 0 else { throw XCTSkip("requires unprivileged filesystem permissions") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).standardizedFileURL
        let home = root.appendingPathComponent("SearchOnly").path
        defer { chmod(home, 0o700); try? FileManager.default.removeItem(at: root) }
        let trash = URL(fileURLWithPath: home).appendingPathComponent(".Trash")
        let original = URL(fileURLWithPath: home).appendingPathComponent("Original/fixture")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = trash.appendingPathComponent("fixture")
        let bytes = Data("owned search-only ancestor".utf8); try bytes.write(to: destination)
        let id = UUID().uuidString
        try TrashBatches.append(.init(original: original.path, destination: destination.path, identity: try XCTUnwrap(FileIdentity.of(destination.path)), bytes: Int64(bytes.count)), id: id, home: home)
        XCTAssertEqual(chmod(home, 0o111), 0)
        let result = try TrashBatches.restore(id: id, home: home)
        XCTAssertEqual(result.items.first?.status, "restored")
        XCTAssertEqual(try Data(contentsOf: original), bytes)
    }
}
