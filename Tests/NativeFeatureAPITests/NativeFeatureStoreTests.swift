import ModuleKit
import SwiftUI
import XCTest
@testable import NativeFeatureAPI

@MainActor final class NativeFeatureStoreTests:XCTestCase {
    private let manifest=ModuleManifest(id:"com.example.native",name:"Fixture",summary:"",symbol:"doc",version:"1.0.0",entries:[.init(id:"home",kind:.page,title:"Fixture",scene:"fixture")])
    private final class Session:NativeFeatureSession {
        let availability:FeatureAvailability
        var refuses=false,pages=0,finishes=0,starts=0,shutdowns=0
        var presentations: [NativeHostPresentation] = []
        func hostPresentationChanged(_ value: NativeHostPresentation) { presentations.append(value) }
        var blocker:NativeFeatureBlocker?
        var navigation:NativeNavigation?
        var drain:() async->Void = {}
        init(_ availability:FeatureAvailability){self.availability=availability}
        func page(_ route:NativeFeatureRoute,navigation:NativeNavigation)->AnyView? {guard availability.acceptsWork else{return nil};self.navigation=navigation;pages += 1;return AnyView(EmptyView())}
        var status:NativeFeatureStatus {.init(modelLoaded:true)}
        func start(){starts+=1}
        func shutdown(){shutdowns+=1}
        func retireVisibility() {}
        func quitBlocker()->NativeFeatureBlocker? {blocker}
        func prepareStop()throws->NativeFeatureDrain {
            if refuses {throw NativeFeatureBusy("owned operation")}
            return .init { [self] in await drain();finishes += 1}
        }
    }
    func testMetadataStatusQuitDisabledAndUnknownRoutesNeverCreateSession() {
        var creations=0
        let definition=NativeFeatureDefinition(manifest:manifest,makeSession:{availability in creations += 1;return Session(availability)})
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in false})
        store.start(manifest.id);store.start("unknown");store.shutdown();XCTAssertNil(store.page(.init(manifest.id,"home")));XCTAssertNil(store.page(.init("unknown","home")))
        XCTAssertFalse(store.status(manifest.id).modelLoaded);store.retireVisibility();XCTAssertNil(store.quitBlocker());XCTAssertEqual(creations,0)
    }
    func testUndeclaredEntryCannotCreateSessionEvenWhenEnabled() {
        var creations=0
        let definition=NativeFeatureDefinition(manifest:manifest,makeSession:{availability in creations += 1;return Session(availability)})
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in true})
        XCTAssertNil(store.page(.init(manifest.id,"other")));XCTAssertEqual(creations,0)
    }
    func testBackgroundStartupOnlyAdmitsEnabledDeclaredContributionsOnce() {
        var sessions:[Session]=[],coldCreations=0
        let cold=NativeFeatureDefinition(manifest:manifest,makeSession:{availability in coldCreations+=1;return Session(availability)})
        func definition(_ id:String)->NativeFeatureDefinition {
            let manifest=ModuleManifest(id:id,name:id,summary:"",symbol:"doc",version:"1",entries:[])
            return .init(manifest:manifest,runsInBackground:true,makeSession:{availability in let session=Session(availability);sessions.append(session);return session})
        }
        let enabled="com.example.background",disabled="com.example.disabled"
        let store=NativeFeatureStore(definitions:[cold,definition(enabled),definition(disabled)],enabled:{$0 != disabled})
        XCTAssertEqual(store.catalog.backgroundFeatures,[enabled,disabled])
        for _ in 0..<2 {for id in [manifest.id,enabled,disabled,"unknown"] {store.startBackground(id)}}
        XCTAssertEqual(coldCreations,0);XCTAssertEqual(sessions.count,1);XCTAssertEqual(sessions.first?.starts,1)
        XCTAssertFalse(store.status(disabled).modelLoaded)
    }
    func testRefusalDoesNotRevokeGenerationOrRemovePage() throws {
        var session:Session?
        let definition=NativeFeatureDefinition(manifest:manifest,makeSession:{availability in let made=Session(availability);session=made;return made})
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in true}),route=NativeFeatureRoute(manifest.id,"home")
        XCTAssertNotNil(store.page(route));session?.refuses=true
        XCTAssertThrowsError(try store.prepareStop(manifest.id));XCTAssertTrue(session?.availability.acceptsWork == true)
        XCTAssertNotNil(store.page(route));XCTAssertEqual(session?.pages,2)
    }
    func testDrainIsJoinedAndOldAvailabilityNeverRevivesAfterNewGeneration() async throws {
        var sessions:[Session]=[]
        let entered=expectation(description:"physical drain"),release=DispatchSemaphore(value:0);defer{release.signal()}
        let definition=NativeFeatureDefinition(manifest:manifest,makeSession:{availability in let made=Session(availability);sessions.append(made);return made})
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in true}),route=NativeFeatureRoute(manifest.id,"home")
        XCTAssertNotNil(store.page(route));let old=try XCTUnwrap(sessions.first)
        old.drain={entered.fulfill();await Task.detached{_ = release.wait(timeout:.now()+5)}.value}
        let first=try XCTUnwrap(store.prepareStop(manifest.id)),second=try XCTUnwrap(store.prepareStop(manifest.id))
        XCTAssertFalse(old.availability.acceptsWork);XCTAssertNil(store.page(route))
        let a=Task{await first.finish()},b=Task{await second.finish()}
        await fulfillment(of:[entered],timeout:2);XCTAssertNil(store.page(route));XCTAssertEqual(sessions.count,1)
        release.signal();await a.value;await b.value
        XCTAssertEqual(old.finishes,1);XCTAssertFalse(store.status(manifest.id).modelLoaded)
        XCTAssertNotNil(store.page(route));XCTAssertEqual(sessions.count,2)
        XCTAssertFalse(old.availability.acceptsWork);XCTAssertTrue(sessions[1].availability.acceptsWork)
    }
    func testFilteredQuitChecksPreserveLegacyGuardSlotsAndRegistrationOrder() {
        var first:Session?,second:Session?
        let other=ModuleManifest(id:"com.example.other",name:"Other",summary:"",symbol:"doc",version:"1.0.0",entries:[.init(id:"home",kind:.page,title:"Other",scene:"other")])
        let a=NativeFeatureDefinition(manifest:manifest,makeSession:{availability in let made=Session(availability);first=made;return made})
        let b=NativeFeatureDefinition(manifest:other,makeSession:{availability in let made=Session(availability);second=made;return made})
        let store=NativeFeatureStore(definitions:[a,b],enabled:{_ in true})
        _=store.page(.init(manifest.id,"home"));_ = store.page(.init(other.id,"home"))
        second?.blocker = .init(reason:"second",route:.init(other.id,"home"))
        XCTAssertNil(store.quitBlocker(manifest.id));XCTAssertEqual(store.quitBlocker()?.reason,"second")
        first?.blocker = .init(reason:"first",route:.init(manifest.id,"home"))
        XCTAssertEqual(store.quitBlocker()?.reason,"first");XCTAssertEqual(store.quitBlocker(other.id)?.reason,"second")
    }
    func testBackgroundStartAndExitCleanupAreOncePerGenerationAndNeverRenderPages() async throws {
        var sessions:[Session]=[]
        let definition=NativeFeatureDefinition(manifest:manifest,makeSession:{availability in
            let session=Session(availability);sessions.append(session);return session
        })
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in true})
        store.shutdown();XCTAssertTrue(sessions.isEmpty)
        store.start(manifest.id);store.start(manifest.id)
        let first=try XCTUnwrap(sessions.first)
        XCTAssertEqual(first.starts,1);XCTAssertEqual(first.pages,0)
        store.shutdown(manifest.id);store.shutdown(manifest.id)
        XCTAssertEqual(first.shutdowns,1);XCTAssertFalse(first.availability.acceptsWork)
        XCTAssertNil(store.page(.init(manifest.id,"home")))
        if let drain=try store.prepareStop(manifest.id){await drain.finish()}
        store.start(manifest.id)
        XCTAssertEqual(sessions.count,2);XCTAssertEqual(sessions[1].starts,1)
        XCTAssertEqual(sessions[1].pages,0);XCTAssertFalse(first.availability.acceptsWork)
    }

    func testHostVisibilityStaysColdAndReplaysOnlyToAdmittedLiveGeneration() async throws {
        var enabled = false, sessions: [Session] = []
        let definition = NativeFeatureDefinition(manifest: manifest, makeSession: { availability in
            let made = Session(availability); sessions.append(made); return made
        })
        let store = NativeFeatureStore(definitions: [definition], enabled: { _ in enabled })
        let route = NativeFeatureRoute(manifest.id, "home")
        store.setWindowPresentation(visible: true, selection: route)
        store.setMenuPanelVisible(true)
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertFalse(store.status(manifest.id).modelLoaded)
        enabled = true; store.start(manifest.id)
        let first = try XCTUnwrap(sessions.first)
        XCTAssertEqual(first.presentations, [.init(windowVisible: true, menuPanelVisible: true, selection: route)])
        store.setMenuPanelVisible(true)
        XCTAssertEqual(first.presentations.count, 1, "Unchanged host facts must not duplicate holders")
        let drain = try XCTUnwrap(store.prepareStop(manifest.id))
        store.setWindowPresentation(visible: false, selection: nil)
        XCTAssertEqual(first.presentations.count, 1, "Retired generations cannot regain sampling demand")
        await drain.finish()
        store.start(manifest.id)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[1].presentations, [.init(windowVisible: false, menuPanelVisible: true)])
        enabled = false
        store.setMenuPanelVisible(false)
        XCTAssertEqual(sessions[1].presentations.count, 1, "An externally disabled owner cannot receive work")
        XCTAssertFalse(store.hostPresentation.menuPanelVisible)
    }
    func testHostSelectionRejectsUndeclaredRouteWithoutAdmittingFeature() {
        var creations = 0
        let definition = NativeFeatureDefinition(manifest: manifest, makeSession: { availability in
            creations += 1; return Session(availability)
        })
        let store = NativeFeatureStore(definitions: [definition], enabled: { _ in true })
        store.setWindowPresentation(visible: true, selection: .init(manifest.id, "undeclared"))
        XCTAssertNil(store.hostPresentation.selection)
        XCTAssertEqual(creations, 0)
    }

    func testNavigationAdmissionQueryNeverConstructsDestinationAndExpiresWithOrigin() async throws {
        var origin:Session?,madeDestination=0,targetEnabled=true
        var target=manifest;target.id="com.example.destination"
        let a=NativeFeatureDefinition(manifest:manifest,makeSession:{availability in let made=Session(availability);origin=made;return made})
        let b=NativeFeatureDefinition(manifest:target,makeSession:{availability in madeDestination+=1;return Session(availability)})
        let targetID=target.id
        let store=NativeFeatureStore(definitions:[a,b],enabled:{id in id != targetID || targetEnabled})
        _=store.page(.init(manifest.id,"home"))
        let navigation=try XCTUnwrap(origin?.navigation),route=NativeFeatureRoute(target.id,"home")
        XCTAssertTrue(navigation.canAdmit(route));XCTAssertEqual(madeDestination,0)
        targetEnabled=false;XCTAssertFalse(navigation.canAdmit(route))
        targetEnabled=true
        let drain=try XCTUnwrap(store.prepareStop(manifest.id))
        XCTAssertFalse(navigation.canAdmit(route));XCTAssertEqual(madeDestination,0)
        await drain.finish()
    }

}
