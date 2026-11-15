import SwiftUI
import XCTest
import ModuleKit
import NativeFeatureAPI
import SpaceFeature
@testable import ThermoApp

@MainActor final class SpaceHostRoutingTests:XCTestCase {
    private final class Session:NativeFeatureSession {
        var requests:[NativePresentationRequest]=[]
        func page(_ route:NativeFeatureRoute,navigation:NativeNavigation)->AnyView?{AnyView(EmptyView())}
        func preparePresentation(_ route:NativeFeatureRoute,options:[String:NativeContextValue]){requests.append(.init(route:route,options:options))}
        var status:NativeFeatureStatus{.init(modelLoaded:true,snapshotReady:true)}
        func retireVisibility(){}
        func quitBlocker()->NativeFeatureBlocker?{nil}
        func prepareStop()throws->NativeFeatureDrain{.init{}}
    }
    func testRegistryOwnsThreeSpacePagesAndLeavesDiskOverviewWithDisk() {
        XCTAssertTrue(BuiltinModules.problems.isEmpty,BuiltinModules.problems.joined(separator:"\n"))
        XCTAssertFalse(HostPageSpecification.pages.contains{$0.argument=="space"})
        for entry in SpaceModule.manifest.entries {
            let page=MainPage.native(.init(SpaceModule.manifest.id,entry.id))
            XCTAssertEqual(page.module,SpaceModule.manifest.id);XCTAssertEqual(BuiltinModules.page(page)?.target,page)
            XCTAssertEqual(MainPage(argument:"space:"+entry.id),page)
        }
        let overview=DiskModule.target("disk:overview")!
        XCTAssertFalse(SpaceModule.owns(overview));XCTAssertEqual(BuiltinModules.owner(overview)?.manifest.id,DiskModule.manifest.id)
    }
    func testOffRevealAndHistoryInvalidationDoNotCreateModelOrDisableDisk() {
        let name="thermo-space-host-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        var made=0,invalidated=0
        let schema=SpaceFeature.registration(services:{SpaceHostServices()})
        let definition=NativeFeatureDefinition(manifest:schema.manifest,pageContracts:schema.pageContracts,invalidateColdState:{_ in invalidated+=1},makeSession:{_ in made+=1;return Session()})
        let models=AppModels(defaults:defaults,nativeDefinitions:[definition])
        let center=ModuleCenter(defaults:defaults,prepareBuiltinStop:{_ in try SpaceModule.prepareStop(models:models)})
        defaults.set(true,forKey:ModulePreferences.key(SpaceModule.manifest.id))
        defaults.set(true,forKey:ModulePreferences.key(DiskModule.manifest.id))
        let previous=MainWindow.state.page;defer{MainWindow.state.page=previous}
        MainWindow.state.page = .native(.init(SpaceModule.manifest.id,"large"));center.setEnabled(SpaceModule.manifest.id,false)
        for entry in SpaceModule.manifest.entries {XCTAssertFalse(center.shows(.native(.init(SpaceModule.manifest.id,entry.id))))}
        XCTAssertTrue(center.shows(DiskModule.target("disk:overview")!))
        XCTAssertEqual(SpaceModule.reveal("/fixture",models:models),.native(.init(SpaceModule.manifest.id,"browse")))
        models.nativeFeatures.retireVisibility();models.nativeFeatures.invalidateAfterRestore(["/fixture"])
        XCTAssertFalse(models.nativeFeatures.status(SpaceModule.manifest.id).modelLoaded);XCTAssertEqual(made,0);XCTAssertEqual(invalidated,1)
    }
    func testRevealIsPreparedBeforeNavigationAndGenericSnapshotReadsSameEntry() {
        let name="thermo-space-reveal-host-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        defaults.set(true,forKey:ModulePreferences.key(SpaceModule.manifest.id))
        let session=Session(),schema=SpaceFeature.registration(services:{SpaceHostServices()})
        let definition=NativeFeatureDefinition(manifest:schema.manifest,pageContracts:schema.pageContracts,makeSession:{_ in session})
        let models=AppModels(defaults:defaults,nativeDefinitions:[definition])
        let target=SpaceModule.reveal("/fixture/folder",models:models)
        XCTAssertEqual(target,.native(.init(SpaceModule.manifest.id,"browse")))
        XCTAssertEqual(session.requests.first?.options,["path":.text("/fixture/folder")])
        XCTAssertTrue(SpaceModule.snapshotReady(["--page","module:"+SpaceModule.manifest.id+":browse"],models:models,started:Date()))
    }
    func testHostRemovalLeaseFinishesIdempotently() {
        var notices=0
        let lease=SpaceHostServices().protectRemoval{notices+=1}
        XCTAssertEqual(AppExitGuard.reply(show:{_ in}),.terminateCancel);XCTAssertEqual(notices,1)
        lease.finish();lease.finish()
        XCTAssertEqual(AppExitGuard.reply(show:{_ in}),.terminateNow)
    }
}
