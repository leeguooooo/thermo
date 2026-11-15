import AppKit
@testable import CleanKit
import ModuleKit
import ThermoL10n
import XCTest
@testable import SpaceFeature
import NativeFeatureAPI

@MainActor final class SpaceModuleLifecycleTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        private let lock=NSLock();private var value=0
        func hit(){lock.lock();value += 1;lock.unlock()}
        var count:Int{lock.lock();defer{lock.unlock()};return value}
    }
    private func directory() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-space-module-"+UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at:root.appendingPathComponent("Downloads"),withIntermediateDirectories:true)
        addTeardownBlock{try? FileManager.default.removeItem(at:root)}
        return root
    }
    private func suite()->(UserDefaults,String) {
        let name="thermo-space-module-"+UUID().uuidString
        return (UserDefaults(suiteName:name)!,name)
    }
    private nonisolated static func tree(_ root:String)->SpaceTree {
        let file=root+"/Downloads/file",downloads=root+"/Downloads"
        let item=SpaceEntry(path:file,name:"file",isDir:false,bytes:5,files:1,sizeState:.complete)
        let folder=SpaceEntry(path:downloads,name:"Downloads",isDir:true,bytes:5,files:1,sizeState:.complete)
        let top=SpaceEntry(path:root,name:"Fixture",isDir:true,bytes:5,files:1,sizeState:.complete)
        return SpaceTree(root:root,scanned:Date(),folders:[
            root:SpaceFolder(entry:top,children:[folder],otherBytes:0,otherCount:0),
            downloads:SpaceFolder(entry:folder,children:[item],otherBytes:0,otherCount:0)],
            large:[LargeFile(path:file,bytes:5,modified:Date())],unreadable:[],complete:true,duration:0,language:L10n.current.rawValue,sizeVersion:1)
    }

    func testColdOffDoesNotLoadCacheReadMetadataScanOrRemove() async throws {
        let root=try directory(),cache=root.appendingPathComponent("cache.json"),calls=Calls()
        SpaceLens.save(Self.tree(root.path),to:cache)
        XCTAssertNotNil(SpaceLens.cached(root:root.path,from:cache))
        let model=SpaceLensModel(services:FixtureSpaceServices(),enabled:{false},root:root.path,cache:cache,measure:{root,_,_ in calls.hit();return Self.tree(root)},remove:{_,_,_,_,_,_ in calls.hit();return CleanResult(id:"fixture",trashed:true)},searchDuplicates:{_,_,_ in calls.hit();return .init(groups:[],issues:[])},readLastOpened:{_ in calls.hit();return nil})
        XCTAssertNil(model.tree)
        model.scan();model.findDuplicates();model.loadLastOpened()
        model.pick([root.appendingPathComponent("Downloads/file").path:5]);model.trash()
        await Task.yield()
        XCTAssertEqual(calls.count,0);XCTAssertEqual(model.work.count,0)
        XCTAssertFalse(model.scanning || model.findingDuplicates || model.loadingLastOpened || model.working)
        XCTAssertTrue(model.basket.isEmpty);XCTAssertNil(model.removalReview())
        model.stopFeature();await model.finishFeatureStop()
    }
    func testStoppingDrainsBothPhysicalScansBeforeDroppingTheirResults() async throws {
        let root=try directory(),scan=expectation(description:"scan"),duplicates=expectation(description:"duplicates")
        let scanRelease=DispatchSemaphore(value:0),duplicateRelease=DispatchSemaphore(value:0)
        defer{scanRelease.signal();duplicateRelease.signal()}
        let model=SpaceLensModel(services:FixtureSpaceServices(),root:root.path,cache:root.appendingPathComponent("cache.json"),measure:{root,_,_ in scan.fulfill();_ = scanRelease.wait(timeout:.now()+5);return Self.tree(root)},searchDuplicates:{_,_,_ in duplicates.fulfill();_ = duplicateRelease.wait(timeout:.now()+5);return .init(groups:[],issues:[])})
        model.scan();model.findDuplicates();await fulfillment(of:[scan,duplicates],timeout:2)
        model.stopFeature()
        var finished=false;let finish=Task{await model.finishFeatureStop();finished=true}
        await Task.yield();XCTAssertFalse(finished)
        scanRelease.signal();await Task.yield();XCTAssertFalse(finished)
        duplicateRelease.signal();await finish.value
        XCTAssertNil(model.tree);XCTAssertNil(model.duplicates);XCTAssertEqual(model.work.count,0)
    }
    func testStoppingDrainsLastOpenedReaderAndCannotPublishItsOldAnswer() async throws {
        let root=try directory(),cache=root.appendingPathComponent("cache.json"),entered=expectation(description:"metadata")
        SpaceLens.save(Self.tree(root.path),to:cache)
        let release=DispatchSemaphore(value:0);defer{release.signal()}
        let model=SpaceLensModel(services:FixtureSpaceServices(),root:root.path,cache:cache,readLastOpened:{_ in entered.fulfill();_ = release.wait(timeout:.now()+5);return Date()})
        XCTAssertNotNil(model.tree)
        model.loadLastOpened();await fulfillment(of:[entered],timeout:2)
        model.stopFeature()
        var finished=false;let finish=Task{await model.finishFeatureStop();finished=true}
        await Task.yield();XCTAssertFalse(finished)
        release.signal();await finish.value
        XCTAssertTrue(model.lastOpened.isEmpty);XCTAssertFalse(model.loadingLastOpened)
    }
    func testConfirmedRemovalRefusesModuleStopUntilThePhysicalActionReturns() async throws {
        let root=try directory(),file=root.appendingPathComponent("Downloads/file"),cache=root.appendingPathComponent("cache.json")
        try Data("owned".utf8).write(to:file);SpaceLens.save(Self.tree(root.path),to:cache)
        let entered=expectation(description:"owned fake removal"),release=DispatchSemaphore(value:0);defer{release.signal()}
        let model=SpaceLensModel(services:FixtureSpaceServices(),root:root.path,cache:cache,remove:{_,_,_,_,_,_ in entered.fulfill();_ = release.wait(timeout:.now()+5);return CleanResult(id:"fixture",trashed:true)})
        let (defaults,name)=suite();defer{defaults.removePersistentDomain(forName:name)}
        let session=SpaceFeatureSession(availability:FeatureAvailability(enabled:{true}),services:FixtureSpaceServices(),cold:SpaceColdInvalidation(clear:{}),cacheURL:{root.appendingPathComponent("cache.json")},makeModel:{gate,_,_ in model.work.enabled=gate;return model})
        _=session.model
        model.toggle(file.path,bytes:5);let review=try XCTUnwrap(model.removalReview())
        model.trash(review:review);await fulfillment(of:[entered],timeout:2)
        XCTAssertThrowsError(try session.prepareStop());XCTAssertFalse(model.work.stopping)
        release.signal();await model.work.finish()
        let finish=try session.prepareStop();await finish.finish()
        XCTAssertFalse(session.status.modelLoaded)
        XCTAssertTrue(FileManager.default.fileExists(atPath:file.path),"the injected remover never deletes a real file")
    }
    func testAcceptedAIRequestIsKeptUntilCompletionWithoutStartingAnother() async throws {
        let root=try directory(),model=SpaceLensModel(services:FixtureSpaceServices(),root:root.path,cache:root.appendingPathComponent("cache.json"))
        let (defaults,name)=suite();defer{defaults.removePersistentDomain(forName:name)}
        let session=SpaceFeatureSession(availability:FeatureAvailability(enabled:{true}),services:FixtureSpaceServices(),cold:SpaceColdInvalidation(clear:{}),cacheURL:{root.appendingPathComponent("cache.json")},makeModel:{gate,_,_ in model.work.enabled=gate;return model})
        _=session.model
        let operation=try XCTUnwrap(model.work.beginOperation())
        XCTAssertThrowsError(try session.prepareStop());XCTAssertFalse(model.work.stopping)
        model.work.endOperation(operation)
        let finish=try session.prepareStop();await finish.finish()
        XCTAssertNil(model.work.beginOperation());XCTAssertFalse(session.status.modelLoaded)
    }



}
