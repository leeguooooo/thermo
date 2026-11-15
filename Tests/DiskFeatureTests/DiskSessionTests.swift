@testable import CleanKit
import ModuleKit
import NativeFeatureAPI
import XCTest
import SwiftUI
@testable import DiskFeature

@MainActor final class DiskSessionTests:XCTestCase {
    private final class Services:DiskServices {
        func requestScanNotifications(){}
        func revealInSpace(_ path:String)->Bool{false}
    }
    private final class Calls:@unchecked Sendable {
        private let lock=NSLock()
        private var count=0
        @discardableResult func hit()->Int{lock.lock();defer{lock.unlock()};count+=1;return count}
        var value:Int{lock.lock();defer{lock.unlock()};return count}
    }
    private func finish(_ predicate:@escaping @MainActor ()->Bool)async {
        for _ in 0..<300 {if predicate(){return};try? await Task.sleep(nanoseconds:10_000_000)}
        XCTFail("Physical fixture did not finish")
    }
    func testColdQueriesAndWindowRetirementDoNotConstructOverview()async throws {
        var sessions=0,models=0,overviews=0
        let cache=DiskCacheEpoch(clear:{})
        let schema=DiskFeature.registration(services:{Services()})
        let definition=NativeFeatureDefinition(manifest:schema.manifest,ui:schema.ui,invalidateColdState:{_ in cache.invalidate()},makeSession:{gate in
            sessions+=1
            return DiskSession(availability:gate,services:Services(),cache:cache,makeDisk:{cache,work in
                models+=1;return DiskModel(enabled:{gate.acceptsWork},cache:cache,explanationWork:work)
            },makeOverview:{cache in
                overviews+=1;return SpaceOverviewModel(cached:nil,diskSpace:nil,readDiskSpace:{nil},cache:cache)
            })
        })
        var enabled=false
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in enabled})
        XCTAssertFalse(store.status(schema.manifest.id).modelLoaded);XCTAssertNil(store.quitBlocker())
        store.retireVisibility();store.invalidateAfterRestore(["/fixture"])
        XCTAssertNil(store.inlineSettings(.init(schema.manifest.id,"protection")))
        XCTAssertTrue(store.windowUI(selection:nil,locations:[.storage]).sidebar.isEmpty)
        XCTAssertEqual(sessions,0);XCTAssertEqual(models,0);XCTAssertEqual(overviews,0)
        enabled=true
        let ui=store.windowUI(selection:nil,locations:[.storage])
        XCTAssertEqual(models,0,"Contribution registration is still deferred until actual sidebar rendering")
        _=try XCTUnwrap(ui.sidebar.first).content{_ in AnyView(EmptyView())}
        XCTAssertEqual(models,1)
        store.retireVisibility();XCTAssertNil(store.quitBlocker());XCTAssertEqual(overviews,0)
        _=store.page(.init(schema.manifest.id,"overview"));XCTAssertEqual(overviews,1)
        let drain=try XCTUnwrap(store.prepareStop(schema.manifest.id));await drain.finish()
        XCTAssertFalse(store.status(schema.manifest.id).modelLoaded)
    }
    func testRestorationBypassesBothLazyCachesWhenFileInvalidationFails()async throws {
        let clears=Calls(),cachedReads=Calls()
        let cache=DiskCacheEpoch(clear:{clears.hit()}) // deliberately leaves every file untouched
        cache.invalidate()
        let io=DiskScanIO(options:{_,_,_ in ScanOptions(projectRoots:[])},cached:{_,_ in
            cachedReads.hit();return .init(items:[],denied:[],started:Date(),duration:0)
        },scan:{_,_,_,_ in XCTFail("Passive cache read must not scan");return .init(items:[],denied:[],started:Date(),duration:0)})
        let old=SpaceOverview(capacity:100,free:10,purgeable:0,entries:[],duration:0)
        let session=DiskSession(availability:FeatureAvailability(enabled:{true}),services:Services(),cache:cache,makeDisk:{cache,work in
            DiskModel(scanIO:io,cache:cache,explanationWork:work)
        },makeOverview:{cache in
            SpaceOverviewModel(cached:cache.permitsCache ? (old,Date()):nil,diskSpace:nil,readDiskSpace:{nil},cache:cache)
        })
        session.disk.loadSaved();await finish{!session.disk.loadingSaved}
        XCTAssertNil(session.disk.report);XCTAssertEqual(cachedReads.value,0)
        XCTAssertNil(session.overview.overview,"Cleanup cache admission cannot consume overview's restore obligation")
        XCTAssertEqual(clears.value,1)
        let drain=try session.prepareStop();await drain.finish()
    }
    func testOverviewMustPhysicallyDrainBeforeReenableAndCannotSaveAfterRetirement()async throws {
        let entered=expectation(description:"overview reader"),release=DispatchSemaphore(value:0)
        defer{release.signal()}
        let reads=Calls(),saves=Calls(),cache=DiskCacheEpoch(clear:{})
        var sessions:[DiskSession]=[]
        let definition=NativeFeatureDefinition(manifest:BuiltinModuleManifests.disk,makeSession:{gate in
            let session=DiskSession(availability:gate,services:Services(),cache:cache,makeDisk:{cache,work in DiskModel(enabled:{gate.acceptsWork},cache:cache,explanationWork:work)},makeOverview:{cache in
                SpaceOverviewModel(cached:nil,diskSpace:nil,read:{token,_ in
                    reads.hit();entered.fulfill();_ = release.wait(timeout:.now()+5)
                    var report=SpaceOverview(capacity:100,free:10,purgeable:0,entries:[],duration:0);report.cancelled=token.isCancelled;return report
                },save:{_ in saves.hit()},readDiskSpace:{nil},enabled:{gate.acceptsWork},cache:cache)
            })
            sessions.append(session);return session
        })
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in true}),route=NativeFeatureRoute(BuiltinModuleManifests.disk.id,"overview")
        _=store.page(route);let old=sessions[0].overview;old.measure()
        await fulfillment(of:[entered],timeout:2)
        let drain=try XCTUnwrap(store.prepareStop(route.module))
        var drained=false;let waiter=Task {await drain.finish();drained=true}
        await Task.yield()
        XCTAssertFalse(drained);XCTAssertNil(store.page(route));XCTAssertEqual(sessions.count,1)
        release.signal();await waiter.value
        XCTAssertEqual(saves.value,0)
        _=store.page(route);XCTAssertEqual(sessions.count,2)
        old.measure();XCTAssertEqual(reads.value,1)
        let next=try XCTUnwrap(store.prepareStop(route.module));await next.finish()
    }
    func testRestoreDuringDrainDeletesLateWriterBeforeFreshAdmission()async throws {
        let home=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-disk-drain-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:home)}
        let late=home.appendingPathComponent("late-cache"),clears=Calls(),reads=Calls()
        let entered=expectation(description:"physical scan"),release=DispatchSemaphore(value:0)
        defer{release.signal()}
        let cache=DiskCacheEpoch(clear:{clears.hit();try? FileManager.default.removeItem(at:late)})
        let io=DiskScanIO(options:{_,_,_ in var options=ScanOptions(projectRoots:[]);options.home=home.path;return options},cached:{_,_ in nil},scan:{_,_,_,_ in
            reads.hit();entered.fulfill();_ = release.wait(timeout:.now()+5)
            try? Data("old scan cache".utf8).write(to:late)
            return .init(items:[],denied:[],started:Date(),duration:0,cancelled:true)
        })
        var sessions:[DiskSession]=[]
        let definition=NativeFeatureDefinition(manifest:BuiltinModuleManifests.disk,invalidateColdState:{_ in cache.invalidate()},makeSession:{gate in
            let session=DiskSession(availability:gate,services:Services(),cache:cache,makeDisk:{cache,work in
                let disk=DiskModel(scanIO:io,enabled:{gate.acceptsWork},cache:cache,explanationWork:work);disk.cleanGuard=Guard(home:home.path);return disk
            })
            sessions.append(session);return session
        })
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in true}),route=NativeFeatureRoute(BuiltinModuleManifests.disk.id,"scan")
        _=store.page(route);let old=sessions[0].disk;old.scan();await fulfillment(of:[entered],timeout:2)
        let drain=try XCTUnwrap(store.prepareStop(route.module))
        let waiter=Task {await drain.finish()}
        store.invalidateAfterRestore([home.path]);XCTAssertFalse(cache.permitsCache)
        release.signal();await waiter.value
        XCTAssertFalse(FileManager.default.fileExists(atPath:late.path));XCTAssertGreaterThanOrEqual(clears.value,2)
        _=store.page(route);XCTAssertEqual(sessions.count,2)
        old.scan();XCTAssertEqual(reads.value,1)
        XCTAssertNil(sessions[1].disk.report)
        let next=try XCTUnwrap(store.prepareStop(route.module));await next.finish()
    }
    func testWindowRetirementRevokesPendingPresentationWithoutDisablingTheFeature() {
        let session=DiskSession(availability:FeatureAvailability(enabled:{true}),services:Services(),cache:DiskCacheEpoch(clear:{}))
        let old=session.presentationGate();XCTAssertTrue(old())
        session.retireVisibility();XCTAssertFalse(old())
        XCTAssertTrue(session.presentationGate()());XCTAssertFalse(session.status.modelLoaded)
    }

}
