import Foundation
import XCTest
@testable import CleanKit

/// File-identity/measurement fixtures; these are not signed installation acceptance.
final class NativeBackupReviewTests: XCTestCase {
    var home = ""
    var receipt: NativeUpdateReceipt!
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath().path
        let id = UUID().uuidString, target = home+"/Applications/Fixture.app"
        let backup = home+"/Applications/.thermo-update-"+id+"/previous.app"
        for path in [target,backup+"/Contents"] { try FileManager.default.createDirectory(atPath:path,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]) }
        try Data(repeating:42,count:8192).write(to:URL(fileURLWithPath:backup+"/Contents/payload"))
        let before = NativeBundleFacts(bundleID:"com.example.fixture",version:"1",build:"1",team:nil,architectures:["arm64"],seal:"fixture-old")
        let after = NativeBundleFacts(bundleID:"com.example.fixture",version:"2",build:"2",team:nil,architectures:["arm64"],seal:"fixture-new")
        receipt = .init(id:id,target:target,backup:backup,phase:"installed",original:before,replacement:after,
                        originalID:try XCTUnwrap(FileIdentity.of(backup)),replacementID:try XCTUnwrap(FileIdentity.of(target)))
        try NativeUpdateTransaction.save(receipt,home:home)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(atPath:home) }
    func testRecoveryMeasuresAllocatedUsageAndRevealsTheRecordedCopy() throws {
        let report = NativeUpdateTransaction.recovery(home:home)
        let usage = try XCTUnwrap(report.backups?.first)
        XCTAssertEqual(usage.path,receipt.backup); XCTAssertEqual(usage.id,receipt.id)
        XCTAssertTrue(usage.complete); XCTAssertNil(usage.issue)
        XCTAssertGreaterThan(try XCTUnwrap(usage.allocatedBytes),0)
        XCTAssertEqual(usage.files,1)
        XCTAssertEqual(try NativeUpdateTransaction.backupURL(receipt,home:home).path,receipt.backup)
    }
    func testChangedReceiptRequiresRefreshingBeforeInspection() throws {
        var changed = receipt!; changed.phase = "unconfirmed"
        try NativeUpdateTransaction.save(changed,home:home)
        XCTAssertThrowsError(try NativeUpdateTransaction.backupURL(receipt,home:home))
        XCTAssertEqual(try NativeUpdateTransaction.backupURL(changed,home:home).path,changed.backup)
    }
    func testMissingAndLinkedBackupStayVisibleWithUnknownUsage() throws {
        try FileManager.default.moveItem(atPath:receipt.backup,toPath:receipt.backup+".saved")
        for linked in [false,true] {
            if linked { try FileManager.default.createSymbolicLink(atPath:receipt.backup,withDestinationPath:receipt.backup+".saved") }
            XCTAssertThrowsError(try NativeUpdateTransaction.backupURL(receipt,home:home))
            let report = NativeUpdateTransaction.recovery(home:home)
            XCTAssertEqual(report.records.count,1)
            let usage = try XCTUnwrap(report.backups?.first)
            XCTAssertFalse(usage.complete); XCTAssertNil(usage.allocatedBytes); XCTAssertNotNil(usage.issue)
            if !linked { XCTAssertTrue(usage.issue?.contains("restore it from History") == true) }
        }
        XCTAssertTrue(FS.exists(receipt.target))
    }
    func testCancelledMeasurementDoesNotBecomeKnownZero() throws {
        let cancelled = ScanCancellation(); cancelled.cancel()
        let usage = try ScanCancellation.withCurrent(cancelled) { NativeUpdateTransaction.backupUsage(receipt,home:home) }
        XCTAssertFalse(usage.complete); XCTAssertNotNil(usage.issue)
        XCTAssertNil(usage.allocatedBytes)
    }
    func testLegacyRecoveryReportDecodesWithoutUsage() throws {
        let report = try JSONDecoder().decode(NativeRecoveryReport.self,from:Data("{\"records\":[],\"issues\":[]}".utf8))
        XCTAssertNil(report.backups)
    }
}
