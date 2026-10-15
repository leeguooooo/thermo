import Foundation
@testable import CleanKit
import XCTest

final class ScanCancellationIsolationTests: XCTestCase {
    func testOverlappingWalksOnlyObserveTheirOwnCancellation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: root.appendingPathComponent("file"))
        let cancelled = ScanCancellation(), active = ScanCancellation()
        let firstEntered = DispatchSemaphore(value: 0), secondEntered = DispatchSemaphore(value: 0)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.addOperation {
            ScanCancellation.withCurrent(cancelled) {
                firstEntered.signal()
                XCTAssertEqual(secondEntered.wait(timeout: .now() + 5), .success)
                cancelled.cancel()
                XCTAssertTrue(ScanCancellation.current === cancelled)
                XCTAssertEqual(FS.size(root.path).files, 0)
            }
            XCTAssertNil(ScanCancellation.current)
        }
        queue.addOperation {
            ScanCancellation.withCurrent(active) {
                XCTAssertEqual(firstEntered.wait(timeout: .now() + 5), .success)
                secondEntered.signal()
                XCTAssertTrue(ScanCancellation.current === active)
                XCTAssertEqual(FS.size(root.path).files, 1)
            }
            XCTAssertNil(ScanCancellation.current)
        }
        queue.waitUntilAllOperationsAreFinished()
    }

    func testScannerInstallsTokenInWorkersAndRestoresCallerScope() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var options = ScanOptions()
        options.home = root.path
        options.projectRoots = []
        options.discoverProjectRoots = false
        options.categories = [.projects]
        let scanner = DiskScanner(options: options)
        scanner.saveReport = false
        let worker = expectation(description: "project worker inherited scanner token")
        scanner.onProgress = { step in
            XCTAssertTrue(ScanCancellation.current === scanner.cancellation)
            if step == "projects" { worker.fulfill() }
        }
        let caller = ScanCancellation()
        ScanCancellation.withCurrent(caller) {
            XCTAssertFalse(scanner.scan().cancelled)
            XCTAssertTrue(ScanCancellation.current === caller)
        }
        wait(for: [worker], timeout: 5)
        XCTAssertNil(ScanCancellation.current)
    }

    func testCancelledAppMeasurementPublishesNoPartialApps() {
        let token = ScanCancellation()
        token.cancel()
        let apps = [InstalledApp(path: "/nonexistent.app", name: "fixture", bundleID: nil)]
        XCTAssertEqual(AppUninstaller.measure(apps, cancellation: token, each: { _ in
            XCTFail("cancelled measurement must not publish a result")
        }), apps)
    }
}
