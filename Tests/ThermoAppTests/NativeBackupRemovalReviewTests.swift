@testable import CleanKit
@testable import ThermoApp
import XCTest

final class NativeBackupRemovalReviewTests: XCTestCase {
    final class Capture: @unchecked Sendable {
        let lock = NSLock(); var values: [NativeBackupRemovalReview] = []
        func add(_ value: NativeBackupRemovalReview) { lock.lock(); defer { lock.unlock() }; values.append(value) }
        var snapshots: [NativeBackupRemovalReview] { lock.lock(); defer { lock.unlock() }; return values }
    }
    @MainActor func testBackupConfirmationKeepsItsPlanWhenTheRecoveryListChanges() async throws {
        let old = NativeBundleFacts(bundleID:"com.example.fixture",version:"1",build:"1",team:nil,architectures:["arm64"],seal:"old")
        let new = NativeBundleFacts(bundleID:"com.example.fixture",version:"2",build:"2",team:nil,architectures:["arm64"],seal:"new")
        let receipt = NativeUpdateReceipt(id:UUID().uuidString,target:"/fixture/A.app",backup:"/fixture/previous.app",phase:"installed",original:old,replacement:new,originalID:"old-id",replacementID:"new-id")
        let plan = NativeBackupRemovalReview(receipt:receipt,allocatedBytes:8192,sizeComplete:true,backupFacts:old,targetFacts:new,backupIdentity:"backup-review",backupRootIdentity:"old-id",targetIdentity:"target-review",parentIdentity:"parent")
        var changed = receipt; changed.target = "/fixture/B.app"; let latest = changed
        let capture = Capture()
        let model = NativeUpdatesModel(read:{ _ in [] },backupReviewer:{ _ in plan },backupRemover:{ value in
            capture.add(value); var result = CleanResult(id:"fixture",trashed:true); result.failed["fixture"] = "fixture refusal"; return result
        },recoveryReader:{ .init(records:[latest]) })
        model.reviewBackupRemoval(receipt)
        for _ in 0..<200 where model.installing { try await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertEqual(model.backupRemovalReview,plan)
        model.refreshRecovery()
        for _ in 0..<200 where model.recoveryLoading { try await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertEqual(model.recoveryRecords.first?.target,latest.target)
        XCTAssertEqual(model.backupRemovalReview,plan)
        model.trashBackup(plan)
        model.trashBackup(plan) // Busy model must not submit the same confirmation twice.
        for _ in 0..<200 where model.installing { try await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertEqual(capture.snapshots,[plan]); XCTAssertNil(model.backupRemovalReview)
        XCTAssertEqual(model.backupCleanupResult?.failed["fixture"],"fixture refusal")
    }
}
