import CleanKit
@testable import DiskFeature
import AppKit
import ModuleKit
import NativeFeatureAPI
import XCTest
@testable import ThermoShell
@testable import ThermoComposition

@MainActor final class DiskExitGuardIntegrationTests:ThermoCompositionTestCase {
    func testBusyDiskFeaturePreventsApplicationExitAndOpensItsReviewPage() {
        let route=NativeFeatureRoute(BuiltinModuleManifests.disk.id,"scan")
        var shown:[MainPage]=[]
        let reply=AppExitGuard.reply(nativeBlocker:{id in
            id==route.module ? .init(reason:"fixture cleanup is writing",route:route):nil
        },show:{shown.append($0)})
        XCTAssertEqual(reply,.terminateCancel)
        XCTAssertEqual(shown,[.native(route)])
    }
}

@MainActor private final class DiskGuardFixtureServices:DiskServices {
    func requestScanNotifications(){}
    func revealInSpace(_ path:String)->Bool{false}
}

extension DiskExitGuardIntegrationTests {
    func testActualCleanupSessionBlocksCoreExitAndDisableUntilPhysicalCompletion()async throws {
        let home=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-disk-exit-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:home)}
        let item=CleanItem(id:"missing-path-fixture",category:.system,title:"Fixture",safety:.safe,bytes:1,paths:[home.appendingPathComponent("already-missing").path])
        let cache=DiskCacheEpoch(clear:{ScanReportCache.invalidate(home:home.path);SpaceOverview.invalidate(home:home.path)})
        var made=0,model:DiskModel?
        let definition=NativeFeatureDefinition(manifest:BuiltinModuleManifests.disk,makeSession:{gate in
            DiskSession(availability:gate,services:DiskGuardFixtureServices(),cache:cache,makeDisk:{cache,work in
                made+=1
                let value=DiskModel(report:.init(items:[item],denied:[],started:Date(),duration:0),enabled:{gate.acceptsWork},cache:cache,explanationWork:work)
                value.cleanGuard=Guard(home:home.path);value.selected=[item.id];model=value;return value
            })
        })
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in true})
        XCTAssertNil(store.quitBlocker());XCTAssertEqual(made,0)
        let route=NativeFeatureRoute(BuiltinModuleManifests.disk.id,"scan")
        _=store.page(route)
        let loaded=try XCTUnwrap(model);loaded.clean()
        XCTAssertTrue(loaded.cleaning)
        var shown:[MainPage]=[]
        XCTAssertEqual(AppExitGuard.reply(nativeBlocker:{store.quitBlocker($0)},show:{shown.append($0)}),.terminateCancel)
        XCTAssertEqual(shown,[.native(route)])
        XCTAssertThrowsError(try store.prepareStop(route.module));XCTAssertTrue(store.canPresent(route))
        for _ in 0..<300 where loaded.cleaning {try? await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertFalse(loaded.cleaning)
        let drain=try XCTUnwrap(store.prepareStop(route.module));await drain.finish()
        XCTAssertFalse(store.status(route.module).modelLoaded)
        XCTAssertEqual(AppExitGuard.reply(nativeBlocker:{store.quitBlocker($0)},show:{_ in}),.terminateNow)
    }
    func testExplanationOperationBlocksCoreExitAndDisableWithoutRunningAI()async throws {
        let cache=DiskCacheEpoch(clear:{})
        var admitted:DiskSession?
        let definition=NativeFeatureDefinition(manifest:BuiltinModuleManifests.disk,ui:.init(hasBackdrop:true),makeSession:{gate in
            let session=DiskSession(availability:gate,services:DiskGuardFixtureServices(),cache:cache)
            admitted=session;return session
        })
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in true})
        // Mounting only the model-free backdrop admits a session, without cache or scan reads.
        _=store.windowUI(selection:.init(BuiltinModuleManifests.disk.id,"scan"),locations:[])
        let session=try XCTUnwrap(admitted)
        XCTAssertFalse(store.status(BuiltinModuleManifests.disk.id).modelLoaded)
        let operation=try XCTUnwrap(session.explanationWork.beginOperation())
        XCTAssertEqual(AppExitGuard.reply(nativeBlocker:{store.quitBlocker($0)},show:{_ in}),.terminateCancel)
        XCTAssertThrowsError(try store.prepareStop(BuiltinModuleManifests.disk.id))
        session.explanationWork.endOperation(operation)
        let drain=try XCTUnwrap(store.prepareStop(BuiltinModuleManifests.disk.id));await drain.finish()
        XCTAssertEqual(AppExitGuard.reply(nativeBlocker:{store.quitBlocker($0)},show:{_ in}),.terminateNow)
    }
}
