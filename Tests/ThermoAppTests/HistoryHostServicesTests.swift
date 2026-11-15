import AgentCore
import HistoryFeature
import ModuleKit
import NativeFeatureAPI
@testable import AppsFeature
import XCTest
@testable import CleanKit
@testable import ThermoApp

@MainActor final class HistoryHostServicesTests: XCTestCase {
    private func review(_ id: String = "fixture") -> TrashRestore {
        .init(id:id,dryRun:true,items:[.init(original:"/restored",destination:"/trash/a",bytes:1,status:"restored")],reviewIdentity:"fixture")
    }
    func testUnstartedRestoreCancellationReleasesGlobalQuitGuardWithoutTouchingFiles() throws {
        let services=HistoryHostServices(restore:{_,_ in XCTFail("cancelled before physical work");throw CancellationError()},invalidate:{_ in XCTFail("nothing restored")})
        let operation=try services.beginRestore(batch:"fixture",review:review())
        XCTAssertEqual(AppExitGuard.reply(show:{_ in}),.terminateCancel)
        operation.cancelBeforeStart()
        XCTAssertEqual(AppExitGuard.reply(show:{_ in XCTFail("cancelled must release")}),.terminateNow)
        operation.cancelBeforeStart()
    }
    func testRestoreKeepsGlobalGuardAndInvalidatesOnlyActualSuccessPaths() async throws {
        let entered=expectation(description:"physical restore"),release=DispatchSemaphore(value:0)
        defer{release.signal()}
        var paths:[String]=[]
        let services=HistoryHostServices(restore:{id,_ in
            entered.fulfill();_ = release.wait(timeout:.now()+5)
            return .init(id:id,dryRun:false,items:[
                .init(original:"/restored",destination:"/trash/a",bytes:1,status:"restored"),
                .init(original:"/kept",destination:"/trash/b",bytes:1,status:"conflict"),
                .init(original:"/already",destination:"/trash/c",bytes:1,status:"alreadyRestored")])
        },invalidate:{paths=$0})
        let operation=try services.beginRestore(batch:"fixture",review:review())
        let task=Task {try await operation.perform()}
        await fulfillment(of:[entered],timeout:2)
        var shown:[MainPage]=[]
        XCTAssertEqual(AppExitGuard.reply(show:{shown.append($0)}),.terminateCancel)
        XCTAssertEqual(shown,[.native(.init(BuiltinModuleManifests.history.id,"home"))])
        // Once physical work begins, abandoning a pending request cannot release its guard.
        operation.cancelBeforeStart()
        XCTAssertEqual(AppExitGuard.reply(show:{_ in}),.terminateCancel)
        release.signal();_=try await task.value
        XCTAssertEqual(paths,["/restored"])
        XCTAssertEqual(AppExitGuard.reply(show:{_ in XCTFail("completed restore")}),.terminateNow)
    }
    func testFailedRestoreReleasesGlobalGuardWithoutInvalidating() async throws {
        let services=HistoryHostServices(restore:{_,_ in throw NSError(domain:"fixture",code:1)},invalidate:{_ in XCTFail("nothing restored")})
        let operation=try services.beginRestore(batch:"fixture",review:review())
        do{_=try await operation.perform();XCTFail("expected failure")}catch{}
        XCTAssertEqual(AppExitGuard.reply(show:{_ in XCTFail("failure must release")}),.terminateNow)
    }
    func testAdmissionIsOneShotAndAbandonedAdmissionReleasesProtection() async throws {
        let services=HistoryHostServices(restore:{id,_ in .init(id:id,dryRun:false,items:[])},invalidate:{_ in XCTFail("nothing restored")})
        var abandoned:(any HistoryRestoration)?=try services.beginRestore(batch:"fixture",review:review())
        XCTAssertNotNil(abandoned)
        XCTAssertEqual(AppExitGuard.reply(show:{_ in}),.terminateCancel)
        abandoned=nil
        for _ in 0..<20 {
            if AppExitGuard.reply(show:{_ in}) == .terminateNow {break}
            await Task.yield()
        }
        XCTAssertEqual(AppExitGuard.reply(show:{_ in}),.terminateNow)
        let operation=try services.beginRestore(batch:"fixture",review:review())
        _=try await operation.perform()
        do{_=try await operation.perform();XCTFail("restore may run only once")}catch{}
        XCTAssertEqual(AppExitGuard.reply(show:{_ in}),.terminateNow)
    }

    func testInvalidReviewCannotAcquireProtectionOrStartWork() {
        let services=HistoryHostServices(restore:{_,_ in XCTFail("invalid review");throw CancellationError()},invalidate:{_ in XCTFail("nothing restored")})
        var unproved=review();unproved.reviewIdentity=nil
        XCTAssertThrowsError(try services.beginRestore(batch:"fixture",review:unproved))
        XCTAssertThrowsError(try services.beginRestore(batch:"other",review:review()))
        XCTAssertEqual(AppExitGuard.reply(show:{_ in XCTFail("no admission")}),.terminateNow)
    }
    func testFollowUpDestinationsKeepEveryExistingRecoveryKind() {
        let cases:[(String,HistoryHostServices.Destination)]=[
            ("nativeUpdate",.nativeRecovery),("nativePreparation",.nativeRecovery),("startup",.startup),
            ("claudeReset",.claudeReset),("browserBackup",.privacy),("timezoneBackup",.privacy),
            ("spotlightShortcut",.searchSettings),("tabArchive",.tabs),("tabBatch",.tabs),("trash",.trash),
            ("agentBackup",.reveal("/fixture")),("worktreeBackup",.reveal("/fixture"))]
        for (kind,expected) in cases {
            let record=OperationRecord(feature:"fixture",action:"test",items:[],undo:.init(kind:kind,ref:"/fixture"))
            XCTAssertEqual(HistoryHostServices.destination(for:record),expected)
        }
        XCTAssertEqual(HistoryHostServices.destination(for:.init(feature:"apps",action:"update",items:[])),.appUpdates)
        XCTAssertNil(HistoryHostServices.destination(for:.init(feature:"fixture",action:"test",items:[],undo:.init(kind:"trashBatch",ref:"/fixture"))))
    }
    func testNativeRecoveryPreparationHappensBeforeNavigation() {
        let name="thermo-history-host-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        defaults.set(true,forKey:ModulePreferences.key(BuiltinModuleManifests.apps.id))
        let group=AppsFeatureModels()
        let definition=NativeFeatureDefinition(manifest:BuiltinModuleManifests.apps,pageContracts:AppsFeature.registration.pageContracts,makeSession:{AppsFeatureSession(availability:$0,makeModels:{group})})
        let models=AppModels(defaults:defaults,nativeDefinitions:[definition])
        var pages:[MainPage]=[]
        HistoryHostServices.perform(.nativeRecovery,models:models,open:{
            XCTAssertTrue(group.native.showRecovery)
            XCTAssertEqual(group.updates.channel,"native")
            pages.append($0)
        })
        XCTAssertEqual(pages,[.native(.init(BuiltinModuleManifests.apps.id,"updates"))])
    }
}
