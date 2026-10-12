import XCTest
@testable import ThermoApp

final class SingleInstanceTests: XCTestCase {
    func testOnlyOneOwnerAndExitReleasesLock() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("app.lock")
        var first: SingleInstanceLock? = try SingleInstanceLock(url: url)
        let second = try SingleInstanceLock(url: url)
        XCTAssertTrue(first!.acquire())
        XCTAssertFalse(second.acquire())
        first = nil
        XCTAssertTrue(second.acquire(), "A leftover lock file must not prevent relaunch")
        XCTAssertFalse(try SingleInstanceLock(url: url).acquire())
    }
}
