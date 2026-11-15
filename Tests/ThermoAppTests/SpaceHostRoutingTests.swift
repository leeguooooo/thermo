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
        XCTAssertTrue(NativeModules.problems.isEmpty,NativeModules.problems.joined(separator:"\n"))
        XCTAssertFalse(HostPageSpecification.pages.contains{$0.argument=="space"})
        for entry in BuiltinModuleManifests.space.entries {
            let page=MainPage.native(.init(BuiltinModuleManifests.space.id,entry.id))
            XCTAssertEqual(page.module,BuiltinModuleManifests.space.id);XCTAssertEqual(NativeModules.page(page)?.target,page)
            XCTAssertEqual(MainPage(argument:"space:"+entry.id),page)
        }
        let overview=MainPage(argument:"disk:overview")!
        XCTAssertNotEqual(overview.module,BuiltinModuleManifests.space.id);XCTAssertEqual(NativeModules.page(overview)?.module.id,BuiltinModuleManifests.disk.id)
    }
    func testOffRevealAndHistoryInvalidationDoNotCreateModelOrDisableDisk() {
        let name="thermo-space-host-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        var made=0,invalidated=0
        let schema=SpaceFeature.registration(services:{SpaceHostServices()})
        let definition=NativeFeatureDefinition(manifest:schema.manifest,pageContracts:schema.pageContracts,invalidateColdState:{_ in invalidated+=1},makeSession:{_ in made+=1;return Session()})
        let models=AppModels(defaults:defaults,nativeDefinitions:[definition])
        let center=ModuleCenter(defaults:defaults,prepareBuiltinStop:{_ in try NativeModules.prepareStop(BuiltinModuleManifests.space.id,models:models)})
        defaults.set(true,forKey:ModulePreferences.key(BuiltinModuleManifests.space.id))
        defaults.set(true,forKey:ModulePreferences.key(BuiltinModuleManifests.disk.id))
        let previous=MainWindow.state.page;defer{MainWindow.state.page=previous}
        MainWindow.state.page = .native(.init(BuiltinModuleManifests.space.id,"large"));center.setEnabled(BuiltinModuleManifests.space.id,false)
        for entry in BuiltinModuleManifests.space.entries {XCTAssertFalse(center.shows(.native(.init(BuiltinModuleManifests.space.id,entry.id))))}
        XCTAssertTrue(center.shows(MainPage(argument:"disk:overview")!))
        XCTAssertEqual(DiskHostServices.spaceDestination("/fixture",models:models),.native(.init(BuiltinModuleManifests.space.id,"browse")))
        models.nativeFeatures.retireVisibility();models.nativeFeatures.invalidateAfterRestore(["/fixture"])
        XCTAssertFalse(models.nativeFeatures.status(BuiltinModuleManifests.space.id).modelLoaded);XCTAssertEqual(made,0);XCTAssertEqual(invalidated,1)
    }
    func testRevealIsPreparedBeforeNavigationAndGenericSnapshotReadsSameEntry() {
        let name="thermo-space-reveal-host-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        defaults.set(true,forKey:ModulePreferences.key(BuiltinModuleManifests.space.id))
        let session=Session(),schema=SpaceFeature.registration(services:{SpaceHostServices()})
        let definition=NativeFeatureDefinition(manifest:schema.manifest,pageContracts:schema.pageContracts,makeSession:{_ in session})
        let models=AppModels(defaults:defaults,nativeDefinitions:[definition])
        let target=DiskHostServices.spaceDestination("/fixture/folder",models:models)
        XCTAssertEqual(target,.native(.init(BuiltinModuleManifests.space.id,"browse")))
        XCTAssertEqual(session.requests.first?.options,["path":.text("/fixture/folder")])
        XCTAssertTrue(models.nativeFeatures.snapshotReady(.init(BuiltinModuleManifests.space.id,"browse"),arguments:["--page","module:"+BuiltinModuleManifests.space.id+":browse"],started:Date()))
    }
    func testHostRemovalLeaseFinishesIdempotently() {
        var notices=0
        let lease=SpaceHostServices().protectRemoval{notices+=1}
        XCTAssertEqual(AppExitGuard.reply(show:{_ in}),.terminateCancel);XCTAssertEqual(notices,1)
        lease.finish();lease.finish()
        XCTAssertEqual(AppExitGuard.reply(show:{_ in}),.terminateNow)
    }
    func testDiskRevealPreparesSpacePathBeforeSelectingTheDestination() {
        let name="thermo-disk-space-bridge-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        defaults.set(true,forKey:ModulePreferences.key(BuiltinModuleManifests.space.id))
        let session=Session(),schema=SpaceFeature.registration(services:{SpaceHostServices()})
        let definition=NativeFeatureDefinition(manifest:schema.manifest,pageContracts:schema.pageContracts,makeSession:{_ in session})
        let models=AppModels(defaults:defaults,nativeDefinitions:[definition]),path="/fixture/folder\nwith-newline"
        var shown:[MainPage]=[]
        XCTAssertTrue(DiskHostServices.reveal(path,models:models,open:{page in
            XCTAssertEqual(session.requests.last?.options,["path":.text(path)],"Path preparation must finish before navigation")
            shown.append(page)
        }))
        XCTAssertEqual(shown,[.native(.init(BuiltinModuleManifests.space.id,"browse"))])
    }
    func testDiskRevealShowsOffDestinationWithoutAdmissionAndRejectsInvalidPaths() {
        let name="thermo-disk-space-off-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        defaults.set(false,forKey:ModulePreferences.key(BuiltinModuleManifests.space.id))
        var made=0,shown:[MainPage]=[]
        let schema=SpaceFeature.registration(services:{SpaceHostServices()})
        let definition=NativeFeatureDefinition(manifest:schema.manifest,pageContracts:schema.pageContracts,makeSession:{_ in made+=1;return Session()})
        let models=AppModels(defaults:defaults,nativeDefinitions:[definition])
        XCTAssertTrue(DiskHostServices.reveal("/fixture",models:models,open:{shown.append($0)}))
        XCTAssertEqual(shown,[.native(.init(BuiltinModuleManifests.space.id,"browse"))]);XCTAssertEqual(made,0)
        XCTAssertFalse(DiskHostServices.reveal("relative/path",models:models,open:{_ in XCTFail("Invalid path navigated")}))
        XCTAssertFalse(DiskHostServices.reveal("/fixture/\0bad",models:models,open:{_ in XCTFail("Invalid path navigated")}))
        XCTAssertEqual(made,0)
    }

}
