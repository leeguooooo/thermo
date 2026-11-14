import Carbon
import ModuleKit
import ModuleHost
import AgentCore
import SearchCore
import XCTest
@testable import ThermoApp

@MainActor final class SearchModuleLifecycleTests: XCTestCase {
    enum Failure: Error { case release, restore }
    final class Lease: CleanScreenHotkeyLease {
        var released = false; var fail = false
        func release() throws { if fail { throw Failure.release }; released = true }
    }
    final class Backend: CleanScreenHotkeyBackend {
        var leases: [Lease] = []; var callbacks: [(Bool) -> Void] = []
        func register(_ key: CleanScreenKeyBinding, event: @escaping (Bool) -> Void) throws -> CleanScreenHotkeyLease {
            let value = Lease(); leases.append(value); callbacks.append(event); return value
        }
    }
    final class Spotlight {
        var released = false; var fails = false; var releases = 0; var restores = 0
        var adapter: SpotlightShortcut {
            SpotlightShortcut(commandSpaceTaken: {!self.released}, release: {self.released = true;self.releases += 1},
                restore: {if self.fails {throw Failure.restore};self.released = false;self.restores += 1},
                released: {self.released}, otherHolder: {nil})
        }
    }
    final class Reader: @unchecked Sendable {
        let entered: XCTestExpectation; let release = DispatchSemaphore(value: 0)
        init(_ entered: XCTestExpectation) { self.entered = entered }
        func query(_ term: String) -> SearchResponse {
            if term == "old" { entered.fulfill(); _ = release.wait(timeout: .now()+4) }
            return .init(query:term,items:[SearchItem(path:"/"+term,name:term,kind:.file)])
        }
    }
    func suite() -> (UserDefaults, String) {
        let name = "thermo-search-module-"+UUID().uuidString
        return (UserDefaults(suiteName:name)!,name)
    }
    func testSearchManifestAndWorkerOwnershipStayInTheRegistry() {
        XCTAssertTrue(BuiltinModules.problems.isEmpty, BuiltinModules.problems.joined(separator:"\n"))
        XCTAssertEqual(BuiltinModules.workerOwner(SearchModule.previewWorker)?.manifest.id,SearchModule.manifest.id)
        XCTAssertTrue(SearchModule.manifest.entries.allSatisfy(SearchModule.supports))
        XCTAssertEqual(SearchModule.manifest.launch,.prewarm)
    }
    func testDisabledSearchAppControlCannotPretendItsWindowWasOpened() async {
        let defaults=UserDefaults.standard,previous=defaults.volatileDomain(forName:UserDefaults.argumentDomain)
        defer{defaults.setVolatileDomain(previous,forName:UserDefaults.argumentDomain)}
        var domain=previous;domain[ModulePreferences.key(BuiltinModuleManifests.search.id)]=false
        defaults.setVolatileDomain(domain,forName:UserDefaults.argumentDomain)
        let host=AppControlHost()
        for action in ["search.show","search.settings","search.useCommandSpace"] {
            let result=await host.handle(AppControlRequest(action:action,dryRun:true))
            XCTAssertFalse(result.succeeded)
            XCTAssertTrue(result.issue?.contains("switched off")==true)
            XCTAssertNil(result.values["windowVisible"])
        }
    }
    func testOffFeatureDoesNotQueryOrRegisterShortcutsOrClaimSpotlight() async throws {
        let (defaults,name)=suite();defer {defaults.removePersistentDomain(forName:name)}
        defaults.set(false,forKey:ModulePreferences.key(BuiltinModuleManifests.search.id))
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let model=LocalSearchModel(directory:directory,module:BuiltinModuleManifests.search,defaults:defaults) {_,_ in XCTFail("query while off");return .init(query:"",items:[])}
        let backend=Backend(),spotlight=Spotlight()
        let shortcuts=LocalSearchShortcut(backend:backend,spotlight:spotlight.adapter,defaults:defaults,module:BuiltinModuleManifests.search,action:{XCTFail("key while off")},record:{_ in})
        defer {shortcuts.shutdown()}
        model.start();model.query="off";model.submit()
        shortcuts.activate();shortcuts.apply(LocalSearchShortcut.optionSpace,persist:false);shortcuts.takeOverSpotlight()
        XCTAssertTrue(backend.leases.isEmpty);XCTAssertEqual(spotlight.releases,0)
        XCTAssertEqual(model.activeQueries,0);XCTAssertFalse(model.searching || model.indexing)
        model.stop();await model.finishStopping();XCTAssertNil(model.store)
    }
    func testStopDrainsAnOlderDetachedQueryAndCannotPublishAfterRetirement() async throws {
        let entered=expectation(description:"old query entered"),reader=Reader(entered)
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {reader.release.signal();try? FileManager.default.removeItem(at:directory)}
        let model=LocalSearchModel(directory:directory) {term,_ in reader.query(term)}
        model.query="old";await fulfillment(of:[entered],timeout:2)
        model.query="new"
        for _ in 0..<100 where model.response.query != "new" {try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertEqual(model.selected?.name,"new")
        model.stop();let finish=Task {await model.finishStopping()}
        await Task.yield()
        XCTAssertNotNil(model.store,"the old reader still owns the database")
        XCTAssertGreaterThan(model.activeQueries,0)
        model.query="must-not-query";XCTAssertFalse(model.searching)
        reader.release.signal();await finish.value
        XCTAssertNil(model.store);XCTAssertEqual(model.activeQueries,0);XCTAssertTrue(model.response.items.isEmpty)
    }
    func testRestartReopensDatabaseAndActuallyIndexesNewFiles() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-search-restart-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let files=root.appendingPathComponent("files"),database=root.appendingPathComponent("index")
        try FileManager.default.createDirectory(at:files,withIntermediateDirectories:true)
        let alpha=files.appendingPathComponent("unique-alpha.txt"),beta=files.appendingPathComponent("unique-beta.txt")
        try Data("alpha".utf8).write(to:alpha)
        let model=LocalSearchModel(directory:database)
        var preferences=SearchPreferences();preferences.roots=[files.path]
        try XCTUnwrap(model.store).savePreferences(preferences)
        model.start();model.query="unique-alpha"
        for _ in 0..<500 where !model.response.items.contains(where:{$0.path == SearchPaths.canonical(alpha.path)}) {try await Task.sleep(nanoseconds:20_000_000)}
        XCTAssertTrue(model.response.items.contains {$0.path == SearchPaths.canonical(alpha.path)})
        model.stop();await model.finishStopping();XCTAssertNil(model.store)
        try Data("beta".utf8).write(to:beta)
        model.start();model.query="unique-beta"
        for _ in 0..<500 where !model.response.items.contains(where:{$0.path == SearchPaths.canonical(beta.path)}) {try await Task.sleep(nanoseconds:20_000_000)}
        XCTAssertTrue(model.response.items.contains {$0.path == SearchPaths.canonical(beta.path)},"reenable must start a fresh indexer, not just show an old cache")
        model.stop();await model.finishStopping()
    }
    func testShortcutReenableRejectsEventsFromTheRetiredLease() throws {
        let (defaults,name)=suite();defer {defaults.removePersistentDomain(forName:name)}
        let backend=Backend(),spotlight=Spotlight();var calls=0
        let model=LocalSearchShortcut(backend:backend,spotlight:spotlight.adapter,defaults:defaults,action:{calls += 1},record:{_ in})
        defer {model.shutdown()}
        model.activate();backend.callbacks[0](true);XCTAssertEqual(calls,1)
        try model.deactivate();XCTAssertTrue(backend.leases[0].released)
        backend.callbacks[0](false);backend.callbacks[0](true);XCTAssertEqual(calls,1)
        model.activate();XCTAssertEqual(backend.leases.count,2)
        backend.callbacks[0](false);backend.callbacks[0](true);XCTAssertEqual(calls,1)
        backend.callbacks[1](true);XCTAssertEqual(calls,2)
    }
    func testShortcutReleaseFailureIsRetainedForVerifiedRetry() throws {
        let (defaults,name)=suite();defer {defaults.removePersistentDomain(forName:name)}
        let backend=Backend(),spotlight=Spotlight()
        let model=LocalSearchShortcut(backend:backend,spotlight:spotlight.adapter,defaults:defaults,action:{XCTFail()},record:{_ in})
        defer {model.shutdown()}
        model.activate();backend.leases[0].fail=true
        XCTAssertThrowsError(try model.deactivate());XCTAssertNotNil(model.issue)
        model.activate();XCTAssertEqual(backend.leases.count,1)
        backend.leases[0].fail=false;try model.deactivate();model.activate()
        XCTAssertEqual(backend.leases.count,2)
    }
    func testSpotlightRestoreFailureRefusesStopAndSuccessfulResumeKeepsTheChosenKey() throws {
        let (defaults,name)=suite();defer {defaults.removePersistentDomain(forName:name)}
        let backend=Backend(),spotlight=Spotlight()
        let model=LocalSearchShortcut(backend:backend,spotlight:spotlight.adapter,defaults:defaults,action:{},record:{_ in})
        defer {model.shutdown()}
        model.takeOverSpotlight();XCTAssertEqual(model.binding,LocalSearchShortcut.commandSpace)
        spotlight.fails=true;XCTAssertThrowsError(try model.deactivate())
        XCTAssertFalse(backend.leases[0].released)
        spotlight.fails=false;try model.deactivate()
        XCTAssertFalse(spotlight.released);XCTAssertNil(model.binding)
        model.activate();XCTAssertTrue(spotlight.released);XCTAssertEqual(model.binding,LocalSearchShortcut.commandSpace)
        XCTAssertEqual(spotlight.releases,2)
    }
}
