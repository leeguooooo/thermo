@testable import ThermoApp
@testable import CleanKit
import Foundation
import XCTest

/// "Review…" on the overview opens a folder in Space Lens, where it can be picked for the Trash.
final class SpaceRevealTests: XCTestCase {
    private func folder(_ path: String) -> SpaceFolder {
        SpaceFolder(entry: SpaceEntry(path: path, name: (path as NSString).lastPathComponent, isDir: true, bytes: 10, files: 1, sizeState: .complete),
                    children: [], otherBytes: 0, otherCount: 0)
    }
    private func tree(_ paths: [String]) -> SpaceTree {
        SpaceTree(root: "/", scanned: Date(), folders: Dictionary(uniqueKeysWithValues: paths.map { ($0, folder($0)) }),
                  large: [], unreadable: [], complete: true, duration: 0, sizeVersion: 1)
    }

    func testAMeasuredFolderOpensItself() {
        let t = tree(["/", "/Users", "/Users/me", "/Users/me/.cache"])
        XCTAssertEqual(SpaceLensModel.nearestFolder("/Users/me/.cache", in: t), "/Users/me/.cache")
    }

    func testAFileOrSmallFolderOpensTheNearestMeasuredParent() {
        let t = tree(["/", "/Users", "/Users/me"])
        XCTAssertEqual(SpaceLensModel.nearestFolder("/Users/me/Downloads/big.dmg", in: t), "/Users/me")
    }

    func testAPathOutsideTheTreeFallsBackToTheRoot() {
        let t = SpaceTree(root: "/Users/me", scanned: Date(), folders: ["/Users/me": folder("/Users/me")],
                          large: [], unreadable: [], complete: true, duration: 0, sizeVersion: 1)
        XCTAssertEqual(SpaceLensModel.nearestFolder("/opt/homebrew", in: t), "/Users/me")
    }

    @MainActor func testRevealBeforeAMeasurementWaitsForTheTree() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = SpaceLensModel(root: dir.path, cache: dir.appendingPathComponent("cache.json"), readLastOpened: { _ in nil })
        model.reveal(dir.path + "/sub")
        XCTAssertEqual(model.path, dir.path + "/sub")
    }
}
