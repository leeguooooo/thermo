import SwiftUI
import XCTest
import ModuleKit
import NativeFeatureAPI
@testable import AppsFeature
@testable import ThermoApp

@MainActor final class AppsHostRoutingTests:XCTestCase {
    func testRegistryOwnsEverySoftwareTabAndShortcutWithoutLoadingModels() {
        XCTAssertTrue(BuiltinModules.problems.isEmpty,BuiltinModules.problems.joined(separator:"\n"))
        XCTAssertTrue(ModuleNavigation.conflicts(BuiltinModules.all).isEmpty)
        XCTAssertFalse(HostPageSpecification.pages.contains{$0.argument=="apps"})
        for entry in AppsModule.manifest.entries {
            let page=MainPage.native(.init(AppsModule.manifest.id,entry.id))
            XCTAssertEqual(page.module,AppsModule.manifest.id)
            XCTAssertEqual(BuiltinModules.page(page)?.target,page)
            XCTAssertEqual(MainPage(argument:"apps:"+entry.id),page)
        }
        XCTAssertEqual(MainPage(argument:"apps:feeds"),.native(.init(AppsModule.manifest.id,"updates")))
        XCTAssertEqual(MainPage(argument:"apps:unknown"),.native(.init(AppsModule.manifest.id,"installed")))
        XCTAssertTrue(AppsModule.manifest.entries.allSatisfy(AppsModule.supports))
        XCTAssertEqual(AppsModule.manifest.entries.first?.navigationKey,"7")
    }
    func testOffNavigationInvalidationAndRecoveryDoNotCreateModelsOrKeepShortcutSeven() {
        let name="thermo-apps-nav-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        defaults.set(true,forKey:ModulePreferences.key(AppsModule.manifest.id))
        var creations=0
        let definition=NativeFeatureDefinition(manifest:AppsModule.manifest,pageContracts:AppsFeature.registration.pageContracts,makeSession:{availability in
            creations+=1;return AppsFeatureSession(availability:availability)
        })
        let models=AppModels(defaults:defaults,nativeDefinitions:[definition])
        let center=ModuleCenter(defaults:defaults,prepareBuiltinStop:{_ in try AppsModule.prepareStop(models:models)})
        let previous=MainWindow.state.page;defer{MainWindow.state.page=previous}
        MainWindow.state.page = .native(.init(AppsModule.manifest.id,"updates"))
        XCTAssertEqual(center.navigationKey(.native(.init(AppsModule.manifest.id,"installed"))),"7")
        center.setEnabled(AppsModule.manifest.id,false)
        for entry in AppsModule.manifest.entries {XCTAssertFalse(center.shows(.native(.init(AppsModule.manifest.id,entry.id))))}
        XCTAssertNil(center.navigationKey(.native(.init(AppsModule.manifest.id,"installed"))))
        XCTAssertNotEqual(MainWindow.state.page.module,AppsModule.manifest.id)
        models.nativeFeatures.retireVisibility();models.nativeFeatures.invalidateAfterRestore(["/fixture"])
        var pages:[MainPage]=[]
        HistoryHostServices.perform(.nativeRecovery,models:models,open:{pages.append($0)})
        XCTAssertEqual(pages,[.native(.init(AppsModule.manifest.id,"updates"))])
        XCTAssertNil(models.nativeFeatures.quitBlocker());XCTAssertFalse(models.nativeFeatures.status(AppsModule.manifest.id).modelLoaded)
        XCTAssertEqual(creations,0)
    }
    func testFeedsAliasPreparesNativeChannelBeforeDisplay() {
        let name="thermo-apps-feed-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        defaults.set(true,forKey:ModulePreferences.key(AppsModule.manifest.id))
        let group=AppsFeatureModels()
        let definition=NativeFeatureDefinition(manifest:AppsModule.manifest,pageContracts:AppsFeature.registration.pageContracts,makeSession:{AppsFeatureSession(availability:$0,makeModels:{group})})
        let models=AppModels(defaults:defaults,nativeDefinitions:[definition])
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
        defaults.set(true,forKey:ModulePreferences.key(AppsModule.manifest.id))
        let session=ReadinessSession()
        let definition=NativeFeatureDefinition(manifest:AppsModule.manifest,makeSession:{_ in session})
        let models=AppModels(defaults:defaults,nativeDefinitions:[definition])
        let route=NativeFeatureRoute(AppsModule.manifest.id,"updates")
        _=models.nativeFeatures.page(route)
        XCTAssertTrue(models.nativeFeatures.snapshotReady(route,arguments:["--page","module:"+AppsModule.manifest.id+":updates"],started:Date()))
        XCTAssertEqual(session.requested,route)
    }
}
