import XCTest
import SwiftUI
import ModuleKit
@testable import NativeFeatureAPI

@MainActor final class NativeFeatureCatalogTests:XCTestCase {
    private let id="com.example.context"
    private var manifest:ModuleManifest {.init(id:id,name:"Fixture",summary:"",symbol:"doc",version:"1",entries:[.init(id:"home",kind:.page,title:"Home"),.init(id:"action",kind:.menuBarItem,title:"Action"),.init(id:"toolbar",kind:.toolbarAction,title:"Tool")])}
    private final class Session:NativeFeatureSession {
        var routes:[NativeFeatureRoute]=[],options:[[String:NativeContextValue]]=[]
        var navigation=NativeNavigation.unavailable
        var invalidations:[[String]]=[]
        func invalidateAfterRestore(_ paths:[String]){invalidations.append(paths)}
        var activated=0
        func page(_ route:NativeFeatureRoute,navigation:NativeNavigation)->AnyView? {routes.append(route);self.navigation=navigation;return AnyView(EmptyView())}
        func preparePresentation(_ route:NativeFeatureRoute,options:[String:NativeContextValue]){routes.append(route);self.options.append(options)}
        func activate(_ ref:NativeUIEntryRef,navigation:NativeNavigation)->Bool {activated+=1;self.navigation=navigation;return true}
        var status:NativeFeatureStatus {.init(snapshotReady:true)}
        func retireVisibility(){}
        func quitBlocker()->NativeFeatureBlocker?{nil}
        func prepareStop()throws->NativeFeatureDrain{.init{}}
    }
    private func definition(_ make:@escaping @MainActor @Sendable (FeatureAvailability)->any NativeFeatureSession)->NativeFeatureDefinition {
        let id=id
        return .init(manifest:manifest,pageContracts:[.init(entry:"home",fields:[.init("app",kind:.text,defaultValue:.text("Default"))],optionFields:[.init("memory",kind:.integer,required:false)],checkOptions:{values in
            if case let .integer(value)?=values["memory"],value<0{throw NativeRouteError("negative")}
        },check:{values in
            guard case let .text(app)?=values["app"],!app.isEmpty else{throw NativeRouteError("empty")}
        })],resolveLegacyPage:{argument in argument=="old" ? .init(id,"home"):nil},makeSession:make)
    }
    func testPureNormalizationAliasesAndMenuProjectionNeverCreateSessions()throws {
        var made=0
        let catalog=try NativeFeatureCatalog(definitions:[definition{_ in made+=1;return Session()}])
        let empty=try catalog.normalize(.init(id,"home")),explicit=try catalog.normalize(.init(id,"home",context:["app":.text("Default")]))
        XCTAssertEqual(empty,explicit);XCTAssertEqual(Set([empty,explicit]).count,1)
        XCTAssertEqual(try catalog.resolveLegacyPage("old"),empty)
        XCTAssertNil(try catalog.resolveLegacyPage("missing"));XCTAssertEqual(catalog.menuEntries.map(\.ref),[.init(id,"action")]);XCTAssertEqual(made,0)
    }
    func testInvalidContextAndNonPagesRejectBeforeFactory()throws {
        var made=0
        let store=NativeFeatureStore(definitions:[definition{_ in made+=1;return Session()}],enabled:{_ in true})
        for route in [NativeFeatureRoute(id,"home",context:["extra":.text("x")]),.init(id,"home",context:["app":.boolean(true)]),.init(id,"home",context:["app":.text("")]),.init(id,"action"),.init("unknown","home")] {
            XCTAssertNil(store.page(route));XCTAssertFalse(store.preparePresentation(.init(route:route)))
        }
        XCTAssertEqual(made,0)
    }
    func testOptionsAreValidatedColdAndDeliveredOnceOutsidePageIdentity()throws {
        let session=Session();var made=0
        let store=NativeFeatureStore(definitions:[definition{_ in made+=1;return session}],enabled:{_ in true})
        let route=NativeFeatureRoute(id,"home")
        for options:[String:NativeContextValue] in [["extra":.integer(1)],["memory":.text("1")],["memory":.integer(-1)]] {
            XCTAssertFalse(store.preparePresentation(.init(route:route,options:options)))
        }
        XCTAssertEqual(made,0)
        XCTAssertTrue(store.preparePresentation(.init(route:route)));XCTAssertEqual(made,0)
        XCTAssertTrue(store.preparePresentation(.init(route:route,options:["memory":.integer(0)])))
        XCTAssertEqual(made,1);XCTAssertEqual(session.options,[["memory":.integer(0)]])
        _=store.page(route);_=store.page(route)
        XCTAssertEqual(session.options.count,1);XCTAssertTrue(session.routes.allSatisfy{$0.context==["app":.text("Default")]})
    }
    func testOffDrainingAndRetiredCallbacksCannotApplyOptionsOrNavigate()async throws {
        var enabled=false,shows=0,made=0
        let session=Session(),route=NativeFeatureRoute(id,"home")
        let store=NativeFeatureStore(definitions:[definition{_ in made+=1;return session}],enabled:{_ in enabled},navigation:.init{_ in shows+=1;return true})
        let request=NativePresentationRequest(route:route,options:["memory":.integer(5)])
        XCTAssertFalse(store.preparePresentation(request));XCTAssertEqual(made,0)
        enabled=true;XCTAssertNotNil(store.page(route));let old=session.navigation
        XCTAssertTrue(old.show(route));XCTAssertEqual(shows,1)
        let drain=try XCTUnwrap(store.prepareStop(id))
        XCTAssertFalse(store.preparePresentation(request));XCTAssertFalse(old.show(route));XCTAssertEqual(shows,1)
        await drain.finish();XCTAssertNotNil(store.page(route))
        XCTAssertFalse(old.show(route));XCTAssertTrue(session.options.isEmpty)
    }
    func testMenuActivationRejectsWrongKindAndSnapshotQueryStaysCold() {
        let session=Session();var made=0
        let store=NativeFeatureStore(definitions:[definition{_ in made+=1;return session}],enabled:{_ in true})
        XCTAssertFalse(store.snapshotReady(.init(id,"home"),arguments:[],started:Date()))
        XCTAssertFalse(store.activate(.init(id,"home")));XCTAssertFalse(store.activate(.init(id,"toolbar")))
        XCTAssertFalse(store.activate(.init("unknown","action")));XCTAssertEqual(made,0)
        XCTAssertTrue(store.activate(.init(id,"action")));XCTAssertEqual(made,1);XCTAssertEqual(session.activated,1)
        XCTAssertTrue(store.snapshotReady(.init(id,"home"),arguments:[],started:Date()))
    }
    func testRequiredContextAndDuplicateMetadataFailClosed()throws {
        let required=NativeFeatureDefinition(manifest:manifest,pageContracts:[.init(entry:"home",fields:[.init("required",kind:.integer)])],makeSession:{_ in Session()})
        let catalog=try NativeFeatureCatalog(definitions:[required])
        XCTAssertThrowsError(try catalog.normalize(.init(id,"home")))
        XCTAssertThrowsError(try NativeFeatureCatalog(definitions:[required,required]))
        let wrong=NativeFeatureDefinition(manifest:manifest,pageContracts:[.init(entry:"action")],makeSession:{_ in Session()})
        XCTAssertThrowsError(try NativeFeatureCatalog(definitions:[wrong]))
    }
    func testPrivateWorkerOwnershipIsColdAndUnambiguous()throws {
        var made=0
        let worker="com.example.preview"
        let first=NativeFeatureDefinition(manifest:manifest,privateWorkers:[worker],makeSession:{_ in made+=1;return Session()})
        let other=ModuleManifest(id:"com.example.other",name:"Other",summary:"",symbol:"doc",version:"1",entries:[])
        let second=NativeFeatureDefinition(manifest:other,makeSession:{_ in made+=1;return Session()})
        let catalog=try NativeFeatureCatalog(definitions:[first,second])
        XCTAssertEqual(catalog.manifests.map(\.id),[id,other.id])
        XCTAssertEqual(catalog.privateWorkers(id),[worker])
        XCTAssertTrue(catalog.privateWorkers(other.id).isEmpty)
        XCTAssertEqual(catalog.workerOwner(worker)?.id,id)
        XCTAssertNil(catalog.workerOwner("unknown"))
        let duplicate=NativeFeatureDefinition(manifest:other,privateWorkers:[worker],makeSession:{_ in Session()})
        XCTAssertThrowsError(try NativeFeatureCatalog(definitions:[first,duplicate]))
        let collision=NativeFeatureDefinition(manifest:other,privateWorkers:[id],makeSession:{_ in Session()})
        XCTAssertThrowsError(try NativeFeatureCatalog(definitions:[first,collision]))
        XCTAssertEqual(made,0)
    }
    func testLegacyLaunchIsValidatedBeforeAnySessionIsCreated()throws {
        var made=0
        let id=self.id
        let valid=NativeFeatureDefinition(manifest:manifest,resolveLegacyLaunch:{args in
            args.contains("--fixture") ? .init(route:.init(id,"home")):nil
        },makeSession:{_ in made+=1;return Session()})
        let catalog=try NativeFeatureCatalog(definitions:[valid])
        XCTAssertNil(try catalog.resolveLegacyLaunch([]))
        XCTAssertEqual(try catalog.resolveLegacyLaunch(["--fixture"])?.route,.init(id,"home"))
        let invalid=NativeFeatureDefinition(manifest:manifest,resolveLegacyLaunch:{_ in .init(route:.init("com.example.other","home"))},makeSession:{_ in made+=1;return Session()})
        XCTAssertThrowsError(try NativeFeatureCatalog(definitions:[invalid]).resolveLegacyLaunch([]))
        let badOptions=NativeFeatureDefinition(manifest:manifest,resolveLegacyLaunch:{_ in .init(route:.init(id,"home"),options:["undeclared":.text("no")])},makeSession:{_ in made+=1;return Session()})
        XCTAssertThrowsError(try NativeFeatureCatalog(definitions:[badOptions]).resolveLegacyLaunch([]))
        let other=ModuleManifest(id:"com.example.other",name:"Other",summary:"",symbol:"doc",version:"1",entries:[.init(id:"home",kind:.page,title:"Home")])
        let duplicate=NativeFeatureDefinition(manifest:other,resolveLegacyLaunch:{_ in .init(route:.init("com.example.other","home"))},makeSession:{_ in made+=1;return Session()})
        XCTAssertThrowsError(try NativeFeatureCatalog(definitions:[valid,duplicate]).resolveLegacyLaunch(["--fixture"]))
        XCTAssertEqual(made,0)
    }
    func testRestoreInvalidationIsExistingOnlyAndDoesNotTouchDrainingGeneration()async throws {
        let session=Session();var made=0
        let store=NativeFeatureStore(definitions:[definition{_ in made+=1;return session}],enabled:{_ in true})
        store.invalidateAfterRestore(["/restored"]);XCTAssertEqual(made,0)
        _=store.page(.init(id,"home"));store.invalidateAfterRestore([]);XCTAssertTrue(session.invalidations.isEmpty)
        store.invalidateAfterRestore(["/restored"]);XCTAssertEqual(session.invalidations,[["/restored"]])
        let drain=try XCTUnwrap(store.prepareStop(id));store.invalidateAfterRestore(["/later"])
        XCTAssertEqual(session.invalidations,[["/restored"]]);await drain.finish()
        store.invalidateAfterRestore(["/cold"]);XCTAssertEqual(made,1)
    }
    func testColdRestoreInvalidationDoesNotAdmitOrPublishIntoDrainingSession()async throws {
        let session=Session();var made=0,cold:[[String]]=[]
        let definition=NativeFeatureDefinition(manifest:manifest,invalidateColdState:{cold.append($0)},makeSession:{_ in made+=1;return session})
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in true})
        store.invalidateAfterRestore(["/first"]);XCTAssertEqual(made,0);XCTAssertEqual(cold,[["/first"]])
        _=store.page(.init(id,"home"));store.invalidateAfterRestore(["/live"])
        XCTAssertEqual(session.invalidations,[["/live"]]);XCTAssertEqual(cold.count,1)
        let drain=try XCTUnwrap(store.prepareStop(id));store.invalidateAfterRestore(["/draining"])
        XCTAssertEqual(session.invalidations,[["/live"]]);XCTAssertEqual(cold,[["/first"],["/draining"]])
        await drain.finish();XCTAssertEqual(made,1)
    }
}
