import XCTest
import ModuleKit
import NativeFeatureAPI
import ThermoL10n
@testable import CleanKit
@testable import SpaceFeature

@MainActor final class SpaceFeatureSessionTests:XCTestCase {
    private let id=BuiltinModuleManifests.space.id
    private func directory()throws->URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-space-session-"+UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock{try? FileManager.default.removeItem(at:root)};return root
    }
    private nonisolated static func tree(_ root:String)->SpaceTree {
        let entry=SpaceEntry(path:root,name:"Fixture",isDir:true,bytes:5,files:1,sizeState:.complete)
        return .init(root:root,scanned:Date(),folders:[root:.init(entry:entry,children:[],otherBytes:5,otherCount:1)],large:[],unreadable:[],complete:true,duration:0,language:L10n.current.rawValue,sizeVersion:1)
    }
    func testMetadataAndOffRequestsDoNotReadCacheConstructServicesOrModels()throws {
        let root=try directory();var services=0,cacheReads=0
        let definition=SpaceFeature.registration(services:{services+=1;return FixtureSpaceServices()},cacheURL:{cacheReads+=1;return root.appendingPathComponent("cache.json")})
        let catalog=try NativeFeatureCatalog(definitions:[definition])
        XCTAssertEqual(try catalog.resolveLegacyPage("space:unknown"),SpaceFeature.route(.browse))
        XCTAssertEqual(try catalog.resolveLegacyPage("space:duplicates"),SpaceFeature.route(.duplicates))
        let store=NativeFeatureStore(catalog:catalog,enabled:{_ in false},navigation:.unavailable)
        XCTAssertNil(store.page(SpaceFeature.route(.browse)))
        XCTAssertFalse(store.preparePresentation(.init(route:SpaceFeature.route(.browse),options:["path":.text(root.path)])))
        XCTAssertNil(store.quitBlocker());XCTAssertFalse(store.status(id).modelLoaded)
        XCTAssertEqual(services,0);XCTAssertEqual(cacheReads,0)
        store.invalidateAfterRestore([root.path]);XCTAssertEqual(services,0);XCTAssertEqual(cacheReads,1)
    }
    func testColdInvalidationCannotReuseCacheEvenIfItsFirstUnlinkFailed()throws {
        let root=try directory(),cache=root.appendingPathComponent("cache.json")
        SpaceLens.save(Self.tree(root.path),to:cache);XCTAssertNotNil(SpaceLens.cached(root:root.path,from:cache))
        let cold=SpaceColdInvalidation(clear:{}) // model must still refresh after an unsuccessful cold unlink
        let session=SpaceFeatureSession(availability:FeatureAvailability(enabled:{true}),services:FixtureSpaceServices(),cold:cold,cacheURL:{cache},makeModel:{gate,services,cache in SpaceLensModel(services:services,enabled:gate,root:root.path,cache:cache)})
        session.invalidateAfterRestore([root.path]);XCTAssertFalse(session.status.modelLoaded)
        XCTAssertTrue(FileManager.default.fileExists(atPath:cache.path))
        XCTAssertNil(session.model.tree,"failed cold unlink must not revive the pre-restore snapshot")
    }
    func testRevealOptionsAreAppliedOnceAndReadinessDoesNotConstructAModel()throws {
        let root=try directory(),cache=root.appendingPathComponent("cache.json");var made=0
        let session=SpaceFeatureSession(availability:FeatureAvailability(enabled:{true}),services:FixtureSpaceServices(),cold:SpaceColdInvalidation(clear:{}),cacheURL:{cache},makeModel:{gate,services,cache in made+=1;return SpaceLensModel(services:services,enabled:gate,root:root.path,cache:cache)})
        XCTAssertFalse(session.snapshotReady(SpaceFeature.route(.browse),arguments:[],started:Date()));XCTAssertEqual(made,0)
        session.preparePresentation(SpaceFeature.route(.browse),options:["path":.text(root.path+"/first")])
        XCTAssertEqual(session.model.path,root.path+"/first")
        session.model.reveal(root.path+"/second")
        _=session.page(SpaceFeature.route(.browse),navigation:.unavailable);_=session.page(SpaceFeature.route(.browse),navigation:.unavailable)
        XCTAssertEqual(session.model.path,root.path+"/second");XCTAssertEqual(made,1)
    }
    func testInvalidRevealRejectsBeforeFactory()throws {
        var made=0
        let schema=SpaceFeature.registration(services:{FixtureSpaceServices()})
        let definition=NativeFeatureDefinition(manifest:schema.manifest,pageContracts:schema.pageContracts,makeSession:{_ in made+=1;fatalError("invalid request")})
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in true})
        for request in [NativePresentationRequest(route:SpaceFeature.route(.browse),options:["path":.text("relative")]),.init(route:SpaceFeature.route(.browse),options:["path":.text("/bad\npath")]),.init(route:SpaceFeature.route(.large),options:["path":.text("/fixture")]),.init(route:SpaceFeature.route(.browse),options:["path":.integer(1)])] {XCTAssertFalse(store.preparePresentation(request))}
        XCTAssertEqual(made,0)
    }
    func testReenableCreatesFreshModelAndColdRestoreDuringDrainInvalidatesItsCache()async throws {
        let root=try directory(),cache=root.appendingPathComponent("cache.json"),cold=SpaceColdInvalidation(cacheURL:{cache})
        SpaceLens.save(Self.tree(root.path),to:cache)
        var enabled=true,sessions:[SpaceFeatureSession]=[],made=0
        let definition=NativeFeatureDefinition(manifest:BuiltinModuleManifests.space,invalidateColdState:{_ in cold.invalidate()},makeSession:{gate in
            let session=SpaceFeatureSession(availability:gate,services:FixtureSpaceServices(),cold:cold,cacheURL:{cache},makeModel:{gate,services,cache in made+=1;return SpaceLensModel(services:services,enabled:gate,root:root.path,cache:cache,measure:{root,_,_ in Self.tree(root)})})
            sessions.append(session);return session
        })
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in enabled}),route=SpaceFeature.route(.browse)
        _=store.page(route);let old=sessions[0].model
        enabled=false;let finish=try XCTUnwrap(store.prepareStop(id))
        store.invalidateAfterRestore([root.path]);XCTAssertFalse(FileManager.default.fileExists(atPath:cache.path))
        await finish.finish();XCTAssertFalse(store.status(id).modelLoaded)
        enabled=true;_=store.page(route);let current=sessions[1].model
        XCTAssertFalse(current === old);XCTAssertEqual(made,2);XCTAssertNil(current.tree)
        old.scan();XCTAssertEqual(old.work.count,0)
        current.scan();await current.work.finish();XCTAssertNotNil(current.tree)
        if let finish=try store.prepareStop(id){await finish.finish()}
    }
}
