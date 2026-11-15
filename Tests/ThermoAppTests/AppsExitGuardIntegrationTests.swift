import AppKit
import XCTest
import ModuleKit
import NativeFeatureAPI
@testable import CleanKit
@testable import AppsFeature
@testable import ThermoApp

@MainActor final class AppsExitGuardIntegrationTests:XCTestCase {
    private final class OrphanCalls: @unchecked Sendable {
        let lock = NSLock()
        private var calls = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; calls += 1; return calls }
        var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    }

    private func store(_ model:AppsModel)->NativeFeatureStore {
        let definition=NativeFeatureDefinition(manifest:BuiltinModuleManifests.apps,makeSession:{availability in
            AppsFeatureSession(availability:availability,makeModels:{AppsFeatureModels(apps:model)})
        })
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in true})
        _=store.page(.init(BuiltinModuleManifests.apps.id,"installed"))
        return store
    }
    @MainActor func testOrphanRemovalSurvivesRetirementAndSerializesFurtherReadsAndWrites() async throws {
        let reads = OrphanCalls(), writes = OrphanCalls()
        let began = expectation(description: "orphan removal")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let data = OrphanData(bundleID: "com.example.orphan", items: [AppLeftover(path: "/fixture", bytes: 1)])
        let model = AppsModel(readOrphans: { _ in _ = reads.next(); return [data] }, removeOrphanData: { _ in
            _ = writes.next(); began.fulfill(); _ = release.wait(timeout: .now() + 5)
            return [CleanResult(id: "leftovers:fixture", trashed: true)]
        })
        model.scanOrphans()
        for _ in 0..<100 where model.scanningOrphans { try await Task.sleep(nanoseconds: 10_000_000) }
        model.selectedOrphans = [data.id]
        model.removeOrphans([data]); await fulfillment(of: [began], timeout: 2)
        model.retire(); model.removeOrphans([data]); model.scanOrphans(); model.load()
        XCTAssertTrue(model.working); XCTAssertEqual(reads.count, 1); XCTAssertEqual(writes.count, 1)
        let store=store(model)
        XCTAssertEqual(AppExitGuard.reply(nativeBlocker:{store.quitBlocker($0)},show: { _ in }), .terminateCancel)
        release.signal()
        for _ in 0..<100 where model.working { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.working)
    }
    @MainActor
    func testConfirmedRemovalSurvivesWindowRetirementAndBlocksQuitWithoutOpeningARealWindow() async throws {
        let began = expectation(description: "removal running")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let model = AppsModel(remove: { _ in
            began.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            return CleanResult(id: "app-data:fixture", trashed: true)
        })
        let store=store(model)
        let app = InstalledApp(path: "/fixture.app", name: "Fixture", bundleID: "com.example.fixture")
        var plan = UninstallPlan(app: app, paths: [], bytes: 0); plan.removeApp = false
        model.uninstall(plan)
        await fulfillment(of: [began], timeout: 5)
        model.retire()
        model.uninstall(plan)
        model.load()
        XCTAssertFalse(model.loading)
        XCTAssertTrue(model.working)
        var pages: [MainPage] = []
        XCTAssertEqual(AppExitGuard.reply(nativeBlocker:{store.quitBlocker($0)},show: { pages.append($0) }), .terminateCancel)
        XCTAssertEqual(pages, [.native(.init(BuiltinModuleManifests.apps.id,"installed"))])
        XCTAssertTrue(model.exitRequested)
        release.signal()
        for _ in 0..<100 where model.working { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.working)
        XCTAssertEqual(AppExitGuard.reply(nativeBlocker:{store.quitBlocker($0)},show: { _ in XCTFail("completed work must allow quit") }), .terminateNow)
    }
}
