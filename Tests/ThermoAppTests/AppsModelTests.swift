import CleanKit
@testable import ThermoApp
import XCTest

final class AppsModelTests: XCTestCase {
    func app(_ name: String, leftovers: [String] = []) -> InstalledApp {
        var a = InstalledApp(path: "/nonexistent-\(UUID().uuidString)/\(name).app", name: name, bundleID: "com.example.\(name)")
        a.bytes = 100
        a.leftovers = leftovers.map { AppLeftover(path: $0, bytes: 10) }
        return a
    }

    func testUninstalledAppLeavesTheListWithoutRescanning() {
        let a = app("A", leftovers: ["/x/a"]), b = app("B")
        let after = AppsModel.afterUninstall([a, b], appPath: a.path, removed: [a.path, "/x/a"])
        XCTAssertEqual(after.map(\.name), ["B"])
        XCTAssertEqual(after.first?.bytes, 100, "other apps keep their measurements")
    }

    func testAppWhoseBundleStaysKeepsOnlyUnmovedFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("A-\(UUID().uuidString).app").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var a = InstalledApp(path: dir, name: "A", bundleID: "com.example.A")
        a.leftovers = [AppLeftover(path: "/x/1", bytes: 1), AppLeftover(path: "/x/2", bytes: 2)]
        let after = AppsModel.afterUninstall([a], appPath: dir, removed: ["/x/1"])
        XCTAssertEqual(after.first?.leftovers.map(\.path), ["/x/2"])
    }

    func testRemovedLeftoversDropOut() {
        let o1 = OrphanData(bundleID: "com.gone.one", items: [AppLeftover(path: "/l/1", bytes: 1)])
        let o2 = OrphanData(bundleID: "com.gone.two", items: [AppLeftover(path: "/l/2", bytes: 1), AppLeftover(path: "/l/3", bytes: 1)])
        let after = AppsModel.afterRemoval([o1, o2], removed: ["/l/1", "/l/2"])
        XCTAssertEqual(after.map(\.bundleID), ["com.gone.two"])
        XCTAssertEqual(after.first?.items.map(\.path), ["/l/3"])
    }
}
