import Foundation
import MenuBarCore
import ModuleKit
import NativeFeatureAPI
import SwiftUI
import XCTest
@testable import MenuBarFeature

@MainActor final class MenuBarOwnershipTests:XCTestCase {
    private final class NativeSession:MenuBarVisibilitySession {
        var completion:(@MainActor (String?)->Void)?
        var failure:String?
        var releases=0
        func activate(completion:@escaping @MainActor (String?)->Void){self.completion=completion}
        func invalidate()->String?{releases+=1;return failure}
    }
    private final class Gate:@unchecked Sendable {
        let began=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
        func read()->[ManagedMenuBarApp]{began.signal();release.wait();return [.init(id:"org.example.stale",name:"Stale")]}
    }
    func testNeverAdmittedOffMenuAndQuitAndEnabledInlineSettingsStayModelCold() {
        var made=0,controllers=0,keys=0,enabled=false
        let recovery=MenuBarRecoveryAuthority(makeController:{controllers+=1;return MenuBarSessionController{_ in NativeSession()}},makeShortcuts:{_,_ in keys+=1;return MenuBarShortcuts(defaults:.standard,toggle:{},restore:{})})
        let definition=MenuBarFeature.registration(recovery:recovery,makeManager:{_,_ in made+=1;fatalError("cold query constructed manager")})
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in enabled}),id=BuiltinModuleManifests.menuBar.id
        XCTAssertTrue(store.retainedMenuContent().isEmpty);XCTAssertNil(store.inlineSettings(.init(id,"management")))
        enabled=true;XCTAssertNotNil(store.inlineSettings(.init(id,"management")))
        XCTAssertTrue(store.retainedMenuContent().isEmpty);store.shutdown();store.shutdown()
        XCTAssertEqual(made,0);XCTAssertEqual(controllers,0);XCTAssertEqual(keys,0)
    }
    func testAcceptedStopJoinsActualDiscoveryAndDoesNotPublishOrRestartOldRead() async throws {
        let suite="MenuBarOwnership."+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        defer{defaults.removePersistentDomain(forName:suite)}
        let gate=Gate(),backend=MenuBarShortcutTests.Backend()
        defer{gate.release.signal()}
        let recovery=MenuBarRecoveryAuthority(makeController:{MenuBarSessionController{_ in NativeSession()}},makeShortcuts:{toggle,restore in MenuBarShortcuts(defaults:defaults,backend:backend,toggle:toggle,restore:restore)})
        var model:MenuBarManager?,enabled=true
        let definition=MenuBarFeature.registration(recovery:recovery,makeManager:{availability,authority in
            let value=MenuBarManager(defaults:defaults,accessibilityTrusted:{true},shortcutBackend:backend,featureEnabled:{availability.acceptsWork},recovery:authority,capabilityAvailable:{true},discover:{gate.read()});model=value;return value
        })
        // Supply fake resource factories too; no private native API or Carbon registration.
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in enabled}),id=BuiltinModuleManifests.menuBar.id
        store.start(id);let existing=try XCTUnwrap(model)
        existing.setPanelOpen(true);await Task.detached{gate.began.wait()}.value
        existing.setPanelOpen(false);existing.setPanelOpen(true)
        let drain=try XCTUnwrap(store.prepareStop(id));enabled=false
        var drained=false;let finish=Task{await drain.finish();drained=true}
        await Task.yield();XCTAssertFalse(drained);XCTAssertTrue(existing.discoveryRunning)
        gate.release.signal();await finish.value
        XCTAssertFalse(existing.discoveryRunning);XCTAssertFalse(existing.apps.contains{$0.id=="org.example.stale"})
        XCTAssertNil(recovery.manager);model=nil;store.shutdown()
    }
    func testLateNativeFailureSurvivesManagerReleaseAndOffRecoveryUsesSameHandle() throws {
        let suite="MenuBarLateRecovery."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!,native=NativeSession(),backend=MenuBarShortcutTests.Backend()
        defer{defaults.removePersistentDomain(forName:suite)}
        var controllers=0
        let recovery=MenuBarRecoveryAuthority(makeController:{controllers+=1;return MenuBarSessionController{_ in native}},makeShortcuts:{toggle,restore in MenuBarShortcuts(defaults:defaults,backend:backend,toggle:toggle,restore:restore)})
        var model:MenuBarManager?=MenuBarManager(defaults:defaults,accessibilityTrusted:{true},featureEnabled:{true},recovery:recovery,capabilityAvailable:{true})
        model?.start();let controller=recovery.controller
        controller.apply(.init(allowedBundles:["org.example.fixture"]))
        try model?.stopFeature();if let model{recovery.detach(model)}
        weak var old=model;model=nil;XCTAssertNil(old)
        let before=defaults.dictionaryRepresentation()
        native.failure="late invalidation failed";native.completion?(nil)
        XCTAssertNotEqual(recovery.state,.visible)
        let content=try XCTUnwrap(recovery.retainedMenu()?.content)
        native.failure=nil
        for node in content.items(.status){if case let .action(action)=node{action.perform()}}
        XCTAssertEqual(recovery.state,.visible);XCTAssertEqual(controllers,1)
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary,before as NSDictionary)
        recovery.shutdown()
    }
}
