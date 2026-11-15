import XCTest
import CleanKit
import ModuleKit
import NativeFeatureAPI
@testable import BrowserFeature

@MainActor final class BrowserSessionTests:XCTestCase {
    private let id=BuiltinModuleManifests.browser.id
    private func diagnostic(_ app:String,_ memory:Int?,_ gpu:Int?)->ChromePagesModel {
        ChromePagesModel(app:app,appMemoryKB:memory,gpuKB:gpu,actions:.init(tabs:{_ in []},close:{_,_ in XCTFail("no close requested");return []},reading:{_ in fatalError("no reading requested")},wait:{}))
    }
    private func workspace(_ app:String)->TabWorkspaceModel {
        .init(app:app,preview:.init(inventory:.init(app:app,generated:Date(),pages:[]),saved:[]))
    }
    func testRouteMetadataDefaultExactSubjectsAndInvalidValues()throws {
        let catalog=try NativeFeatureCatalog(definitions:[BrowserFeature.registration])
        XCTAssertEqual(try catalog.normalize(.init(id,"home")),BrowserFeature.route("Google Chrome"))
        for app in ["Arc","Microsoft Edge","Browser: Personal"] {
            XCTAssertEqual(try catalog.resolveLegacyPage("pages:"+app),BrowserFeature.route(app))
        }
        XCTAssertEqual(try catalog.resolveLegacyPage("pages:"),BrowserFeature.route("Google Chrome"))
        for app in ["","bad\nname","bad\0name"] {XCTAssertThrowsError(try catalog.normalize(BrowserFeature.route(app)))}
        XCTAssertThrowsError(try catalog.normalizePresentation(.init(route:BrowserFeature.route("Arc"),options:["gpuMemoryKB":.integer(-1)])))
        XCTAssertThrowsError(try catalog.normalizePresentation(.init(route:BrowserFeature.route("Arc"),options:["appMemoryKB":.text("5")])))
    }
    func testDiagnosticsAndWorkspaceAreIndependentAndSnapshotIsSubjectSpecific() {
        var diagnosticApps:[String]=[],workspaceApps:[String]=[]
        let session=BrowserSession(availability:FeatureAvailability(enabled:{true}),makeDiagnostics:{_,app,m,g in diagnosticApps.append(app);return self.diagnostic(app,m,g)},makeWorkspace:{_,app in workspaceApps.append(app);return self.workspace(app)})
        XCTAssertFalse(session.status.modelLoaded)
        XCTAssertFalse(session.snapshotReady(BrowserFeature.route("Arc"),arguments:[],started:Date()))
        XCTAssertTrue(diagnosticApps.isEmpty);XCTAssertTrue(workspaceApps.isEmpty)
        let model=session.diagnostics("Arc")
        model.accept(.init(app:"Arc",mode:.tabs,tabs:[],duplicates:[]),tabs:[])
        XCTAssertTrue(session.snapshotReady(BrowserFeature.route("Arc"),arguments:["--tabs-task","diagnostics"],started:Date()))
        XCTAssertFalse(session.snapshotReady(BrowserFeature.route("Google Chrome"),arguments:["--tabs-task","diagnostics"],started:Date()))
        XCTAssertTrue(workspaceApps.isEmpty)
        _=session.workspace("Microsoft Edge")
        XCTAssertTrue(session.snapshotReady(BrowserFeature.route("Microsoft Edge"),arguments:[],started:Date()))
        XCTAssertFalse(session.snapshotReady(BrowserFeature.route("Arc"),arguments:[],started:Date()))
        XCTAssertEqual(diagnosticApps,["Arc"]);XCTAssertEqual(workspaceApps,["Microsoft Edge"])
    }
    func testResourceHintsReachInitializerAndLaterOmissionsPreserveOwnedReadings() {
        var hints:[[Int?]]=[],workspaceCreations=0
        let session=BrowserSession(availability:FeatureAvailability(enabled:{true}),makeDiagnostics:{_,app,m,g in hints.append([m,g]);return self.diagnostic(app,m,g)},makeWorkspace:{_,app in workspaceCreations+=1;return self.workspace(app)})
        let route=BrowserFeature.route("Arc")
        session.preparePresentation(route,options:["appMemoryKB":.integer(42),"gpuMemoryKB":.integer(7)])
        XCTAssertEqual(hints,[[42,7]]);XCTAssertEqual(workspaceCreations,0)
        let model=session.diagnostics("Arc")
        model.accept(.init(app:"Arc",mode:.tabs,tabs:[],duplicates:[]),tabs:[])
        model.appMemoryKB=100;model.gpuKB=nil // native post-close readings replace earlier hints
        _=session.page(route,navigation:.unavailable);_=session.page(route,navigation:.unavailable)
        session.preparePresentation(route,options:[:])
        XCTAssertEqual(model.appMemoryKB,100);XCTAssertNil(model.gpuKB)
        session.preparePresentation(route,options:["gpuMemoryKB":.integer(0)])
        XCTAssertEqual(model.appMemoryKB,100);XCTAssertEqual(model.gpuKB,0)
        XCTAssertEqual(hints.count,1);XCTAssertFalse(model.running);XCTAssertNotNil(model.diagnosis)
    }
    func testArchiveUsesDeclaredMenuEntryAndRollsBackIfNavigationRefused() {
        let session=BrowserSession(availability:FeatureAvailability(enabled:{true}))
        XCTAssertFalse(session.activate(.init(id,"home"),navigation:.unavailable));XCTAssertFalse(session.archive.requested)
        XCTAssertFalse(session.activate(.init(id,"archive"),navigation:.unavailable));XCTAssertFalse(session.archive.requested)
        var selected:NativeFeatureRoute?
        XCTAssertTrue(session.activate(.init(id,"archive"),navigation:.init{request in selected=request.route;return true}))
        XCTAssertTrue(session.archive.requested);XCTAssertEqual(selected,BrowserFeature.route("Google Chrome"))
        XCTAssertFalse(session.status.modelLoaded)
    }
    func testOldGenerationCannotReviveAfterDrainAndNewSessionHasNoPendingArchive()async throws {
        var enabled=true,sessions:[BrowserSession]=[]
        let definition=NativeFeatureDefinition(manifest:BuiltinModuleManifests.browser,pageContracts:BrowserFeature.registration.pageContracts,makeSession:{gate in
            let session=BrowserSession(availability:gate,makeDiagnostics:{gate,app,m,g in
                let model=self.diagnostic(app,m,g);model.work.enabled=gate;return model
            },makeWorkspace:{gate,app in let model=self.workspace(app);model.work.enabled=gate;return model})
            sessions.append(session);return session
        })
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in enabled}),route=BrowserFeature.route("Arc")
        XCTAssertNotNil(store.page(route));let old=sessions[0],model=old.workspace("Arc")
        old.archive.requested=true
        let drain=try XCTUnwrap(store.prepareStop(id));enabled=false
        XCTAssertNil(store.page(route));await drain.finish();XCTAssertFalse(old.archive.requested)
        enabled=true;XCTAssertNotNil(store.page(route));XCTAssertEqual(sessions.count,2)
        model.refresh();await model.work.finish();XCTAssertTrue(model.work.stopping)
        XCTAssertFalse(sessions[1].status.modelLoaded);XCTAssertFalse(sessions[1].archive.requested)
    }
}
