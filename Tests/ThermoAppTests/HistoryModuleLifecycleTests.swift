import AgentCore
import ModuleKit
import XCTest
@testable import CleanKit
@testable import ThermoApp

@MainActor final class HistoryModuleLifecycleTests:XCTestCase {
    private func defaults()->UserDefaults {
        let name="thermo-history-module-"+UUID().uuidString
        let result=UserDefaults(suiteName:name)!
        addTeardownBlock{result.removePersistentDomain(forName:name)}
        return result
    }
    private func record()->OperationRecord {
        .init(feature:"fixture",action:"test",items:[.init(target:"/fixture",status:"done")],undo:.init(kind:"trashBatch",ref:UUID().uuidString))
    }
    private func review(_ record:OperationRecord)->TrashRestore {
        .init(id:record.undo!.ref,dryRun:true,items:[.init(original:"/fixture",destination:"/fixture-trash",bytes:1,status:"restored")],reviewIdentity:"fixture")
    }
    func testRegistryOwnsLegacyAndGenericHistoryPage() {
        XCTAssertTrue(BuiltinModules.problems.isEmpty,BuiltinModules.problems.joined(separator:"\n"))
        XCTAssertEqual(MainPage.history.module,HistoryModule.manifest.id)
        XCTAssertEqual(BuiltinModules.page(.history)?.target,.history)
        XCTAssertEqual(BuiltinModules.page(.module(HistoryModule.manifest.id,"home"))?.target,.history)
    }
    func testColdOffCannotReadReviewOrRestore() async {
        let model=HistoryModel(enabled:{false},reader:{XCTFail("off history read");return .init(records:[])},reviewBatch:{_ in XCTFail("off restore review");throw NSError(domain:"fixture",code:1)},restoreBatch:{_,_ in XCTFail("off restore");throw NSError(domain:"fixture",code:1)})
        let record=record();model.load();model.prepareRestore(record);model.restore(record,review:review(record))
        await model.work.finish()
        XCTAssertFalse(model.loaded || model.reading || model.busy || model.reviewingRestore)
        XCTAssertTrue(model.records.isEmpty)
    }
    func testStopDrainsPhysicalReadAndRejectsLateRecords() async {
        let entered=expectation(description:"journal read"),release=DispatchSemaphore(value:0),record=record()
        defer{release.signal()}
        let model=HistoryModel(reader:{entered.fulfill();_ = release.wait(timeout:.now()+5);return .init(records:[record])})
        model.load();await fulfillment(of:[entered],timeout:2)
        model.stopFeature()
        var drained=false;let finish=Task {await model.finishFeatureStop();drained=true}
        await Task.yield();XCTAssertFalse(drained)
        release.signal();await finish.value
        XCTAssertTrue(model.records.isEmpty);XCTAssertFalse(model.loaded || model.reading)
    }
    func testStopDrainsRestoreReviewAndDoesNotPublishItsLateResult() async {
        let entered=expectation(description:"restore review"),release=DispatchSemaphore(value:0),record=record()
        let result=review(record)
        defer{release.signal()}
        let model=HistoryModel(reader:{.init(records:[])},reviewBatch:{id in
            entered.fulfill();_ = release.wait(timeout:.now()+5)
            var result=result;result.id=id;return result
        })
        model.prepareRestore(record);await fulfillment(of:[entered],timeout:2)
        model.stopFeature()
        var drained=false;let finish=Task {await model.finishFeatureStop();drained=true}
        await Task.yield();XCTAssertFalse(drained)
        release.signal();await finish.value
        XCTAssertNil(model.restoreReview);XCTAssertFalse(model.reviewingRestore)
    }
    func testAcceptedRestoreRefusesFeatureStopUntilPhysicalActionCompletes() async throws {
        let entered=expectation(description:"fake restore"),release=DispatchSemaphore(value:0)
        defer{release.signal()}
        let model=HistoryModel(reader:{.init(records:[])},restoreBatch:{id,_ in
            entered.fulfill();_ = release.wait(timeout:.now()+5)
            return .init(id:id,dryRun:false,items:[])
        },didRestore:{_ in})
        let models=AppModels(defaults:defaults(),makeHistory:{gate in model.work.enabled=gate;return model})
        _=models.history
        let record=record();model.restore(record,review:review(record))
        await fulfillment(of:[entered],timeout:2)
        XCTAssertThrowsError(try HistoryModule.prepareStop(models:models));XCTAssertFalse(model.work.stopping)
        release.signal();await model.work.finish()
        if let finish=try HistoryModule.prepareStop(models:models){await finish()}
        XCTAssertFalse(models.historyLoaded)
    }
    func testOffPresentationDoesNotDeleteKernelJournalAndReenableReadsNewRecords() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-history-lifetime-"+UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let first=record();OperationJournal.record(first,home:root.path)
        let defaults=defaults();var creations=0
        let models=AppModels(defaults:defaults,makeHistory:{gate in creations += 1;return HistoryModel(enabled:gate,reader:{OperationJournal.readReport(home:root.path)})})
        let old=models.history;old.load();await old.work.finish()
        XCTAssertEqual(old.records.map(\.id),[first.id])
        defaults.set(false,forKey:ModulePreferences.key(HistoryModule.manifest.id))
        if let finish=try HistoryModule.prepareStop(models:models){await finish()}
        XCTAssertFalse(models.historyLoaded);XCTAssertTrue(old.records.isEmpty)
        let second=record();OperationJournal.record(second,home:root.path)
        old.load();XCTAssertEqual(old.work.count,0)
        XCTAssertEqual(Set(OperationJournal.read(home:root.path).map(\.id)),Set([first.id,second.id]))
        defaults.set(true,forKey:ModulePreferences.key(HistoryModule.manifest.id))
        let fresh=models.history;XCTAssertFalse(old === fresh);XCTAssertEqual(creations,2)
        fresh.load();await fresh.work.finish()
        XCTAssertEqual(Set(fresh.records.map(\.id)),Set([first.id,second.id]))
        if let finish=try HistoryModule.prepareStop(models:models){await finish()}
    }
    func testOffNavigationDoesNotCreateHistoryModel() {
        let defaults=defaults();var creations=0
        let models=AppModels(defaults:defaults,makeHistory:{gate in creations += 1;return HistoryModel(enabled:gate,reader:{.init(records:[])})})
        let center=ModuleCenter(defaults:defaults,prepareBuiltinStop:{_ in try HistoryModule.prepareStop(models:models)})
        center.setEnabled(HistoryModule.manifest.id,false)
        XCTAssertFalse(center.shows(.history));XCTAssertFalse(models.historyLoaded);XCTAssertEqual(creations,0)
    }

}
