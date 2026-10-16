@testable import CleanKit
@testable import ThermoApp
import XCTest

final class NativeRestoreReviewTests: XCTestCase {
    private final class Capture: @unchecked Sendable {
        let lock = NSLock(); private var value: NativeUpdateReceipt?
        func set(_ receipt: NativeUpdateReceipt) { lock.lock(); defer { lock.unlock() }; value = receipt }
        var receipt: NativeUpdateReceipt? { lock.lock(); defer { lock.unlock() }; return value }
    }
    @MainActor func testConfirmedRecoveryCarriesTheWholeReviewedReceipt() async throws {
        let before = NativeBundleFacts(bundleID: "com.example.fixture", version: "1.0", build: "1", team: nil, architectures: ["arm64"], seal: "old-seal")
        let after = NativeBundleFacts(bundleID: "com.example.fixture", version: "2.0", build: "2", team: nil, architectures: ["arm64"], seal: "new-seal")
        let reviewed = NativeUpdateReceipt(id: UUID().uuidString, target: "/fixture/Reviewed.app", backup: "/fixture/previous.app", phase: "installed", original: before, replacement: after, originalID: "old-id", replacementID: "new-id")
        var latest = reviewed; latest.target = "/fixture/Changed.app"
        let current = latest
        let capture = Capture()
        let model = NativeUpdatesModel(read: { _ in [] }, restorer: { receipt in
            capture.set(receipt); return .init(outcome: "failed", message: "fixture refusal")
        }, recoveryReader: { .init(records: [current]) })
        model.refreshRecovery()
        for _ in 0..<200 where model.recoveryLoading { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.recoveryRecords.first?.target, current.target)
        model.restore(reviewed)
        for _ in 0..<200 where model.installing { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(capture.receipt, reviewed)
        XCTAssertEqual(model.installResult?.outcome, "failed")
        XCTAssertFalse(model.installing)
    }
}
