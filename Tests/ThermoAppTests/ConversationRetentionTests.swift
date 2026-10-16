import CleanKit
import XCTest
@testable import ThermoApp

final class ConversationRetentionTests: XCTestCase {
    @MainActor func testDefaultDoesNotSelectSessionsFromLegacyReports() {
        let item = CleanItem(id:"codex-sessions/fixture",category:.aiSessions,title:"Fixture",safety:.review,bytes:4096,paths:["/fixture/chat.jsonl"])
        let model = DiskModel(report:.init(items:[item],denied:[],started:Date(),duration:0))
        model.selected = [item.id]
        XCTAssertNil(model.sessionRetentionDays); XCTAssertTrue(model.selectedItems.isEmpty)
    }
    @MainActor func testChangingRetentionInvalidatesAnAlreadyConfirmedPlan() throws {
        let item = CleanItem(id:"fixture",category:.aiCaches,title:"Fixture",safety:.review,bytes:4096,paths:["/fixture/cache"])
        let model = DiskModel(report:.init(items:[item],denied:[],started:Date(),duration:0));model.selected = [item.id]
        let confirmation = try XCTUnwrap(model.cleanupReview())
        model.setSessionRetentionDays(90)
        XCTAssertNil(model.report); XCTAssertTrue(model.selected.isEmpty)
        XCTAssertFalse(model.isCurrentCleanupReview(confirmation))
        model.setSessionRetentionDays(nil)
        XCTAssertNil(model.sessionRetentionDays); XCTAssertTrue(model.selectedItems.isEmpty)
    }
    @MainActor func testExplicitAgeMustMatchTheReportBeforeChatCanBeSelected() {
        let model = DiskModel();model.setSessionRetentionDays(90)
        let item = CleanItem(id:"codex-sessions/fixture",category:.aiSessions,title:"Fixture",safety:.review,bytes:4096,paths:["/fixture/chat.jsonl"])
        var report = ScanReport(items:[item],denied:[],started:Date(),duration:0)
        report.categories = [.aiSessions]
        report.sessionRetentionDays = 30;report.sessionPolicyVersion = ScanOptions.sessionPolicyVersion
        model.acceptScan(report);model.selected = [item.id]
        XCTAssertTrue(model.selectedItems.isEmpty); XCTAssertTrue(model.scopeNeedsRefresh(category:.aiSessions))
        report.sessionRetentionDays = 90;model.acceptScan(report);model.selected = [item.id]
        XCTAssertEqual(model.selectedItems.map(\.id),[item.id])
        XCTAssertEqual(DiskModel.scanOptions(scope:.all,sessionRetentionDays:90).olderThanDays,30)
        XCTAssertFalse(model.scopeNeedsRefresh(category:.aiSessions))
        XCTAssertNil(DiskModel.scanOptions(scope:.all,sessionRetentionDays:90).sessionRetentionDays)
        XCTAssertEqual(DiskModel.scanOptions(scope:.ai,sessionRetentionDays:90).sessionRetentionDays,90)
        XCTAssertEqual(DiskModel.scanOptions(scope:.all,category:.aiSessions,sessionRetentionDays:90).sessionRetentionDays,90)
    }
}
