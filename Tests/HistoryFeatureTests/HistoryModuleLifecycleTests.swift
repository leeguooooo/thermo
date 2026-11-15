import AgentCore
import ModuleKit
import XCTest
@testable import CleanKit
import NativeFeatureAPI
@testable import HistoryFeature

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
        let manifest=BuiltinModuleManifests.history
        let definition=NativeFeatureDefinition(manifest:manifest,makeSession:{availability in
            HistorySession(availability:availability,services:TestHistoryServices(),makeModel:{gate,_ in model.work.enabled=gate;return model})
        })
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in true})
        _=store.page(.init(manifest.id,"home"))
        let record=record();model.restore(record,review:review(record))
        await fulfillment(of:[entered],timeout:2)
        XCTAssertNotNil(store.quitBlocker())
        XCTAssertThrowsError(try store.prepareStop(manifest.id));XCTAssertFalse(model.work.stopping)
        release.signal();await model.work.finish()
        if let drain=try store.prepareStop(manifest.id){await drain.finish()}
        XCTAssertFalse(store.status(manifest.id).modelLoaded)
    }

    func testOffPresentationDoesNotDeleteKernelJournalAndReenableReadsNewRecords() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-history-lifetime-"+UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let first=record();OperationJournal.record(first,home:root.path)
        var enabled=true,models:[HistoryModel]=[]
        let manifest=BuiltinModuleManifests.history
        let definition=NativeFeatureDefinition(manifest:manifest,makeSession:{availability in
            HistorySession(availability:availability,services:TestHistoryServices(),makeModel:{gate,_ in
                let model=HistoryModel(enabled:gate,reader:{OperationJournal.readReport(home:root.path)})
                models.append(model);return model
            })
        })
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in enabled}),route=NativeFeatureRoute(manifest.id,"home")
        _=store.page(route)
        let old=try XCTUnwrap(models.first);old.load();await old.work.finish()
        XCTAssertEqual(old.records.map(\.id),[first.id])
        enabled=false
        if let drain=try store.prepareStop(manifest.id){await drain.finish()}
        XCTAssertFalse(store.status(manifest.id).modelLoaded);XCTAssertTrue(old.records.isEmpty)
        let second=record();OperationJournal.record(second,home:root.path)
        old.load();XCTAssertEqual(old.work.count,0)
        XCTAssertEqual(Set(OperationJournal.read(home:root.path).map(\.id)),Set([first.id,second.id]))
        enabled=true;_=store.page(route)
        let fresh=try XCTUnwrap(models.last);XCTAssertFalse(old === fresh);XCTAssertEqual(models.count,2)
        fresh.load();await fresh.work.finish()
        XCTAssertEqual(Set(fresh.records.map(\.id)),Set([first.id,second.id]))
        if let drain=try store.prepareStop(manifest.id){await drain.finish()}
    }

    func testOffNavigationDoesNotCreateHistoryModel() {
        var creations=0
        let manifest=BuiltinModuleManifests.history
        let definition=NativeFeatureDefinition(manifest:manifest,makeSession:{availability in
            creations+=1
            return HistorySession(availability:availability,services:TestHistoryServices())
        })
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in false})
        XCTAssertNil(store.page(.init(manifest.id,"home")))
        store.retireVisibility();XCTAssertNil(store.quitBlocker());XCTAssertFalse(store.status(manifest.id).modelLoaded)
        XCTAssertEqual(creations,0)
    }
}
