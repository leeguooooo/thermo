import XCTest
import ModuleKit
import NativeFeatureAPI
@testable import AppsFeature

@MainActor final class AppsFeatureSessionTests:XCTestCase {
    private let id=BuiltinModuleManifests.apps.id
    func testMetadataStatusQuitReadinessAndInvalidationNeverCreateModels()async throws {
        var creations=0
        let session=AppsFeatureSession(availability:FeatureAvailability(enabled:{true}),makeModels:{creations+=1;return AppsFeatureModels()})
        session.retireVisibility();session.invalidateAfterRestore(["/fixture"])
        XCTAssertFalse(session.status.modelLoaded);XCTAssertNil(session.quitBlocker())
        XCTAssertFalse(session.snapshotReady(.init(id,"updates"),arguments:[],started:Date()))
        let drain=try session.prepareStop();await drain.finish();XCTAssertEqual(creations,0)
    }
    func testUpdatePresentationAppliesOnlySuppliedFieldsAndDoesNotReplayOnRender() {
        let group=AppsFeatureModels();var creations=0
        let session=AppsFeatureSession(availability:FeatureAvailability(enabled:{true}),makeModels:{creations+=1;return group})
        let route=NativeFeatureRoute(id,"updates")
        session.preparePresentation(route,options:["channel":.text("native"),"showRecovery":.boolean(true)])
        XCTAssertEqual(creations,1);XCTAssertEqual(group.updates.channel,"native");XCTAssertTrue(group.native.showRecovery)
        group.native.showRecovery=false;group.updates.channel="homebrew"
        _=session.page(route,navigation:.unavailable);_=session.page(route,navigation:.unavailable)
        XCTAssertFalse(group.native.showRecovery);XCTAssertEqual(group.updates.channel,"homebrew")
        session.preparePresentation(route,options:["showRecovery":.boolean(true)])
        XCTAssertTrue(group.native.showRecovery);XCTAssertEqual(group.updates.channel,"homebrew")
    }
    func testOptionsForOtherPagesAndInvalidChannelsRejectBeforeSessionCreation()throws {
        var creations=0
        let production=AppsFeature.registration
        let definition=NativeFeatureDefinition(manifest:production.manifest,pageContracts:production.pageContracts,makeSession:{gate in creations+=1;return AppsFeatureSession(availability:gate)})
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in true})
        for request in [NativePresentationRequest(route:.init(id,"installed"),options:["showRecovery":.boolean(true)]),.init(route:.init(id,"updates"),options:["channel":.text("unknown")]),.init(route:.init(id,"updates"),options:["showRecovery":.text("true")])] {
            XCTAssertFalse(store.preparePresentation(request))
        }
        XCTAssertEqual(creations,0)
    }
    func testRestoreInvalidationClearsOnlyExistingInventoryState() {
        var creations=0
        let session=AppsFeatureSession(availability:FeatureAvailability(enabled:{true}),makeModels:{creations+=1;return AppsFeatureModels()})
        session.invalidateAfterRestore(["/fixture"]);XCTAssertEqual(creations,0)
        let apps=session.models.apps;apps.outcome="old result"
        session.invalidateAfterRestore([]);XCTAssertEqual(apps.outcome,"old result")
        session.invalidateAfterRestore(["/fixture"]);XCTAssertNil(apps.outcome);XCTAssertEqual(creations,1)
    }
}
