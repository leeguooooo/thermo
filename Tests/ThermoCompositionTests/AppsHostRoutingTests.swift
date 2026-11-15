import SwiftUI
import XCTest
import ModuleKit
import NativeFeatureAPI
@testable import AppsFeature
@testable import ThermoShell
@testable import ThermoComposition

@MainActor final class AppsHostRoutingTests:ThermoCompositionTestCase {
    func testRegistryOwnsEverySoftwareTabAndShortcutWithoutLoadingModels() {
        XCTAssertTrue(NativeModules.problems.isEmpty,NativeModules.problems.joined(separator:"\n"))
        XCTAssertTrue(ModuleNavigation.conflicts(NativeModules.all).isEmpty)
        XCTAssertFalse(HostPageSpecification.pages.contains{$0.argument=="apps"})
        for entry in BuiltinModuleManifests.apps.entries {
            let page=MainPage.native(.init(BuiltinModuleManifests.apps.id,entry.id))
            XCTAssertEqual(page.module,BuiltinModuleManifests.apps.id)
            XCTAssertEqual(NativeModules.page(page)?.target,page)
            XCTAssertEqual(MainPage(argument:"apps:"+entry.id),page)
        }
        XCTAssertEqual(MainPage(argument:"apps:feeds"),.native(.init(BuiltinModuleManifests.apps.id,"updates")))
        XCTAssertEqual(MainPage(argument:"apps:unknown"),.native(.init(BuiltinModuleManifests.apps.id,"installed")))

        XCTAssertEqual(BuiltinModuleManifests.apps.entries.first?.navigationKey,"7")
    }
    func testOffNavigationInvalidationAndRecoveryDoNotCreateModelsOrKeepShortcutSeven() {
        let name="thermo-apps-nav-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        defaults.set(true,forKey:ModulePreferences.key(BuiltinModuleManifests.apps.id))
        var creations=0
        let definition=NativeFeatureDefinition(manifest:BuiltinModuleManifests.apps,pageContracts:AppsFeature.registration.pageContracts,makeSession:{availability in
            creations+=1;return AppsFeatureSession(availability:availability)
        })
        let models=ShellState(defaults:defaults,nativeDefinitions:[definition])
        let center=ModuleCenter(defaults:defaults,prepareBuiltinStop:{_ in try NativeModules.prepareStop(BuiltinModuleManifests.apps.id,models:models)})
        let previous=MainWindow.state.page;defer{MainWindow.state.page=previous}
        MainWindow.state.page = .native(.init(BuiltinModuleManifests.apps.id,"updates"))
        XCTAssertEqual(center.navigationKey(.native(.init(BuiltinModuleManifests.apps.id,"installed"))),"7")
        center.setEnabled(BuiltinModuleManifests.apps.id,false)
        for entry in BuiltinModuleManifests.apps.entries {XCTAssertFalse(center.shows(.native(.init(BuiltinModuleManifests.apps.id,entry.id))))}
        XCTAssertNil(center.navigationKey(.native(.init(BuiltinModuleManifests.apps.id,"installed"))))
        XCTAssertNotEqual(MainWindow.state.page.module,BuiltinModuleManifests.apps.id)
        models.nativeFeatures.retireVisibility();models.nativeFeatures.invalidateAfterRestore(["/fixture"])
        var pages:[MainPage]=[]
        HistoryHostServices.perform(.nativeRecovery,environment:.referencing(models.nativeFeatures),open:{pages.append(.native($0))})
        XCTAssertEqual(pages,[.native(.init(BuiltinModuleManifests.apps.id,"updates"))])
        XCTAssertNil(models.nativeFeatures.quitBlocker());XCTAssertFalse(models.nativeFeatures.status(BuiltinModuleManifests.apps.id).modelLoaded)
        XCTAssertEqual(creations,0)
    }
    func testFeedsAliasPreparesNativeChannelBeforeDisplay() {
        let name="thermo-apps-feed-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        defaults.set(true,forKey:ModulePreferences.key(BuiltinModuleManifests.apps.id))
        let group=AppsFeatureModels()
        let definition=NativeFeatureDefinition(manifest:BuiltinModuleManifests.apps,pageContracts:AppsFeature.registration.pageContracts,makeSession:{AppsFeatureSession(availability:$0,makeModels:{group})})
        let models=ShellState(defaults:defaults,nativeDefinitions:[definition])
        let page=MainPage(argument:"apps:feeds")!
        models.nativeFeatures.prepareReview(page.nativeRoute!,arguments:["--page","apps:feeds"])
        XCTAssertEqual(group.updates.channel,"native")
    }
    private final class ReadinessSession:NativeFeatureSession {
        var requested:NativeFeatureRoute?
        func page(_ route:NativeFeatureRoute,navigation:NativeNavigation)->AnyView?{AnyView(EmptyView())}
        var status:NativeFeatureStatus{.init(snapshotReady:true)}
        func snapshotReady(_ route:NativeFeatureRoute,arguments:[String],started:Date)->Bool{requested=route;return true}
        func retireVisibility(){}
        func quitBlocker()->NativeFeatureBlocker?{nil}
        func prepareStop()throws->NativeFeatureDrain{.init{}}
    }
    func testGenericModuleSnapshotUsesTheRequestedSoftwareEntry() {
        let name="thermo-apps-snapshot-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        defaults.set(true,forKey:ModulePreferences.key(BuiltinModuleManifests.apps.id))
        let session=ReadinessSession()
        let definition=NativeFeatureDefinition(manifest:BuiltinModuleManifests.apps,makeSession:{_ in session})
        let models=ShellState(defaults:defaults,nativeDefinitions:[definition])
        let route=NativeFeatureRoute(BuiltinModuleManifests.apps.id,"updates")
        _=models.nativeFeatures.page(route)
        XCTAssertTrue(models.nativeFeatures.snapshotReady(route,arguments:["--page","module:"+BuiltinModuleManifests.apps.id+":updates"],started:Date()))
        XCTAssertEqual(session.requested,route)
    }
}
