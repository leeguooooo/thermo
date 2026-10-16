import CleanKit
import Foundation
import ThermoL10n
import XCTest
@testable import ThermoApp

final class ConversationRetentionTests: XCTestCase {
    func preferences() -> (UserDefaults,ConversationRetentionPreferences) {
        let name="dev.thermo.tests.retention."+UUID().uuidString
        let isolated=UserDefaults(suiteName:name)!
        addTeardownBlock { isolated.removePersistentDomain(forName:name) }
        return (isolated,.stored(in:isolated))
    }
    @MainActor func testExplicitChoiceSurvivesModelRecreationWithoutRestoringAPlan() {
        let (_,preferences)=preferences(),first=DiskModel(retentionPreferences:preferences)
        first.setSessionRetentionDays(90)
        let reopened=DiskModel(retentionPreferences:preferences)
        XCTAssertEqual(reopened.sessionRetentionDays,90);XCTAssertNil(reopened.report)
        XCTAssertTrue(reopened.selected.isEmpty);XCTAssertTrue(reopened.excluded.isEmpty);XCTAssertFalse(reopened.scanning)
        reopened.setSessionRetentionDays(nil)
        XCTAssertNil(DiskModel(retentionPreferences:preferences).sessionRetentionDays)
    }
    @MainActor func testRestoredAgeNeverAutomaticallySelectsConversations() {
        let (_,preferences)=preferences();preferences.write(90)
        let reopened=DiskModel(retentionPreferences:preferences)
        let item=CleanItem(id:"session",category:.aiSessions,title:"Fixture",safety:.safe,bytes:4096,paths:["/fixture/session"])
        var report=ScanReport(items:[item],denied:[],started:Date(),duration:0)
        report.sessionRetentionDays=90;report.sessionPolicyVersion=ScanOptions.sessionPolicyVersion
        reopened.acceptScan(report)
        XCTAssertTrue(reopened.selectedItems.isEmpty);XCTAssertTrue(reopened.selected.isEmpty)
        reopened.selected=[item.id];XCTAssertEqual(reopened.selectedItems.count,1)
        XCTAssertTrue(DiskModel(retentionPreferences:preferences).selectedItems.isEmpty)
    }
    @MainActor func testMalformedFutureOrUnsupportedPreferencesKeepAllConversations() {
        let (defaults,preferences)=preferences()
        for raw in ["{}","{\"version\":2,\"days\":90}","{\"version\":1,\"days\":0}","{\"version\":1,\"days\":-1}","{\"version\":1,\"days\":999999999}","{\"version\":1,\"days\":true}","{\"version\":1,\"days\":\"90\"}",String(repeating:"x",count:2048)] {
            defaults.set(Data(raw.utf8),forKey:ConversationRetentionPreferences.key)
            XCTAssertNil(DiskModel(retentionPreferences:preferences).sessionRetentionDays,raw)
        }
        defaults.set("90",forKey:ConversationRetentionPreferences.key)
        XCTAssertNil(DiskModel(retentionPreferences:preferences).sessionRetentionDays)
        let model=DiskModel(retentionPreferences:preferences);model.setSessionRetentionDays(nil)
        XCTAssertNil(defaults.object(forKey:ConversationRetentionPreferences.key))
    }
    @MainActor func testUnsupportedSelectionDoesNotDiscardAReviewedPlanOrSavedChoice() throws {
        let (_,preferences)=preferences();preferences.write(90)
        let item=CleanItem(id:"cache",category:.aiCaches,title:"Fixture",safety:.review,bytes:4096,paths:["/fixture/cache"])
        let model=DiskModel(report:.init(items:[item],denied:[],started:Date(),duration:0),retentionPreferences:preferences)
        model.selected=[item.id];let review=try XCTUnwrap(model.cleanupReview())
        for value in [0,-1,2,Int.max] { model.setSessionRetentionDays(value) }
        XCTAssertEqual(model.sessionRetentionDays,90);XCTAssertEqual(preferences.read(),90);XCTAssertTrue(model.isCurrentCleanupReview(review))
    }
    @MainActor func testScanningCannotChangeTheSavedChoice() async {
        let (_,preferences)=preferences();preferences.write(90)
        let release=DispatchSemaphore(value:0)
        let io=DiskScanIO(options:{ _,category,days in
            var options=ScanOptions(projectRoots:[]);options.sessionRetentionDays=days;options.categories=category.map { [$0] } ?? [];return options
        },cached:{ _,_ in nil },scan:{ _,_,_,_ in
            _=release.wait(timeout:.now()+5)
            return ScanReport(items:[],denied:[],started:Date(),duration:0)
        })
        let model=DiskModel(scanIO:io,requestNotifications:{},retentionPreferences:preferences)
        model.scan(category:.aiSessions);XCTAssertTrue(model.scanning)
        model.setSessionRetentionDays(30);XCTAssertEqual(model.sessionRetentionDays,90);XCTAssertEqual(preferences.read(),90)
        model.stop();release.signal()
        for _ in 0..<200 where model.scanning { try? await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertFalse(model.scanning)
    }
    @MainActor func testRestoredChoiceRejectsMismatchedCacheAndKeepsMatchingSessionsUnticked() async throws {
        let (_,preferences)=preferences();preferences.write(90)
        let home=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-retention-cache-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:home) }
        var options=ScanOptions(projectRoots:[]);options.home=home.path;options.discoverProjectRoots=false;options.categories=[.aiSessions]
        let frozen=options
        let io=DiskScanIO(options:{ _,_,days in var value=frozen;value.sessionRetentionDays=days;return value },cached:DiskScanIO.live.cached,scan:{ _,_,_,_ in
            XCTFail("loading saved results must not start a scan");return ScanReport(items:[],denied:[],started:Date(),duration:0)
        })
        let item=CleanItem(id:"session",category:.aiSessions,title:"Fixture",safety:.safe,bytes:4096,paths:[home.path+"/session"])
        var report=ScanReport(items:[item],denied:[],started:Date(),duration:0)
        report.language=L10n.current.rawValue;report.categories=[.aiSessions];report.projectRoots=[];report.discoverProjectRoots=false
        report.olderThanDays=options.olderThanDays;report.sessionPolicyVersion=ScanOptions.sessionPolicyVersion;report.sessionRetentionDays=30
        ScanReportCache.save(report,home:home.path)
        let model=DiskModel(scanIO:io,requestNotifications:{},retentionPreferences:preferences)
        model.loadSaved(category:.aiSessions)
        for _ in 0..<200 where model.loadingSaved { try? await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertFalse(model.loadingSaved);XCTAssertNil(model.report)
        report.sessionRetentionDays=90;ScanReportCache.save(report,home:home.path)
        model.loadSaved(category:.aiSessions)
        for _ in 0..<200 where model.loadingSaved { try? await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertEqual(model.report?.sessionRetentionDays,90);XCTAssertTrue(model.selected.isEmpty);XCTAssertTrue(model.selectedItems.isEmpty)
    }
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
