import AgentCore
import CleanKit
import ModuleHost
import ModuleKit
import NativeFeatureAPI
@testable import DiskFeature
import XCTest
@testable import ThermoApp

@MainActor final class BuiltinModuleLifecycleTests: XCTestCase {
    let diskID = BuiltinModules.disk.id
    func defaults() -> (UserDefaults, String) {
        let name = "thermo-builtin-stop-" + UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }
    func center(_ defaults: UserDefaults, models: AppModels) -> ModuleCenter {
        ModuleCenter(defaults: defaults, prepareBuiltinStop: { _ in try DiskModule.prepareStop(models:models) })
    }
    private final class Services:DiskServices {
        func requestScanNotifications(){}
        func revealInSpace(_ path:String)->Bool{false}
    }
    private final class Box {var session:DiskSession?}
    private func fixture(_ defaults:UserDefaults,make:@escaping @MainActor (DiskCacheEpoch,FeatureTasks)->DiskModel)->(AppModels,Box) {
        let box=Box()
        let definition=NativeFeatureDefinition(manifest:BuiltinModuleManifests.disk,makeSession:{gate in
            let session=DiskSession(availability:gate,services:Services(),cache:DiskCacheEpoch(clear:{}),makeDisk:make)
            box.session=session;return session
        })
        return (AppModels(defaults:defaults,nativeDefinitions:[definition]),box)
    }
    private func admit(_ models:AppModels,_ box:Box)->DiskModel {
        _=models.nativeFeatures.page(.init(diskID,"scan"));return box.session!.disk
    }
    func eventually(_ predicate: @escaping @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Feature stop did not complete")
    }
    func testStoppingAnUnusedFeatureDoesNotCreateItsModel() {
        let (settings, name) = defaults(); defer { settings.removePersistentDomain(forName: name) }
        var made = 0
        let (models,_)=fixture(settings){cache,work in made+=1;return DiskModel(requestNotifications:{},cache:cache,explanationWork:work)}
        let host = center(settings, models: models)
        host.setEnabled(diskID, false)
        XCTAssertFalse(host.isOn(diskID))
        XCTAssertFalse(models.nativeFeatures.status(diskID).modelLoaded)
        XCTAssertEqual(made, 0)
        XCTAssertTrue(host.changing.isEmpty)
    }
    func testAnInFlightScanIsCancelledAndDrainedBeforeTheCacheIsReleased() async {
        let (settings, name) = defaults(); defer { settings.removePersistentDomain(forName: name) }
        let began = expectation(description: "scan started"), cancelled = expectation(description: "scan cancelled")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let io = DiskScanIO(options: { _,_,_ in ScanOptions(projectRoots: []) }, cached: { _,_ in nil },
            scan: { _, token, _, _ in
                began.fulfill()
                let end = Date().addingTimeInterval(3)
                while !token.isCancelled && Date() < end { Thread.sleep(forTimeInterval: 0.005) }
                XCTAssertTrue(token.isCancelled); cancelled.fulfill()
                _ = release.wait(timeout: .now()+5)
                return ScanReport(items: [], denied: [], started: Date(), duration: 0, cancelled: true)
            })
        let (models,box)=fixture(settings){cache,work in DiskModel(scanIO:io,requestNotifications:{},cache:cache,explanationWork:work)}
        let host = center(settings, models: models)
        var held:DiskModel?=admit(models,box)
        weak var previous = held
        held!.scan()
        await fulfillment(of: [began], timeout: 2)
        host.setEnabled(diskID, false)
        XCTAssertFalse(host.isOn(diskID))
        XCTAssertTrue(host.changing.contains(diskID))
        XCTAssertTrue(models.nativeFeatures.status(diskID).modelLoaded, "The draining worker still owns this model")
        await fulfillment(of: [cancelled], timeout: 2)
        host.setEnabled(diskID, true)
        XCTAssertFalse(host.isOn(diskID), "Re-enable must wait for the old worker")
        release.signal()
        await eventually { !host.changing.contains(self.diskID) }
        XCTAssertFalse(models.nativeFeatures.status(diskID).modelLoaded)
        held!.scan(); held!.loadSaved(scanIfMissing: true)
        XCTAssertFalse(held!.scanning)
        XCTAssertFalse(held!.loadingSaved)
        host.setEnabled(diskID, true)
        let fresh=admit(models,box)
        XCTAssertFalse(fresh === held, "Re-enable creates a fresh model while the old reference is still alive")
        held = nil
        await eventually { previous == nil }
    }
    func testPendingSavedReadCannotRestartAfterDisable() async {
        let (settings, name) = defaults(); defer { settings.removePersistentDomain(forName: name) }
        let began = expectation(description: "cached read started")
        let release = DispatchSemaphore(value: 0); defer { release.signal() }
        let io = DiskScanIO(options: { _,_,_ in ScanOptions(projectRoots: []) }, cached: { _,_ in
            began.fulfill(); _ = release.wait(timeout: .now()+5); return nil
        }, scan: { _,_,_,_ in
            XCTFail("A disabled feature started a scan")
            return ScanReport(items: [], denied: [], started: Date(), duration: 0)
        })
        let (models,box)=fixture(settings){cache,work in DiskModel(scanIO:io,requestNotifications:{},cache:cache,explanationWork:work)}
        let host = center(settings, models: models)
        admit(models,box).loadSaved(scanIfMissing:true)
        await fulfillment(of: [began], timeout: 2)
        host.setEnabled(diskID, false)
        XCTAssertTrue(host.changing.contains(diskID))
        release.signal()
        await eventually { !host.changing.contains(self.diskID) }
        XCTAssertFalse(models.nativeFeatures.status(diskID).modelLoaded)
    }
    func testAStartedCleanupCannotBeInterruptedByDisable() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-stop-clean-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        // A target that is already missing runs the real cleanup queue without deleting files or launching tools.
        let item = CleanItem(id: "missing-path-fixture", category: .system, title: "Fixture", safety: .safe, bytes: 1, paths: [home.appendingPathComponent("already-missing").path])
        let report = ScanReport(items: [item], denied: [], started: Date(), duration: 0)
        let model = DiskModel(report: report, requestNotifications: {})
        model.cleanGuard = Guard(home: home.path)
        model.selected = [item.id]
        model.clean()
        XCTAssertTrue(model.cleaning)
        XCTAssertFalse(model.prepareToDisable())
        await eventually { !model.cleaning }
        XCTAssertTrue(model.prepareToDisable())
        await model.finishDisabling()
    }
    func testRefusedStopPreservesTheEnabledPreferenceAndExplainsWhy() {
        let (settings, name) = defaults(); defer { settings.removePersistentDomain(forName: name) }
        settings.set(true, forKey: ModuleCenter.key(diskID))
        let host = ModuleCenter(defaults: settings, prepareBuiltinStop: { _ in
            throw BuiltinModules.StopRefused(description: "operation is still writing")
        })
        host.setEnabled(diskID, false)
        XCTAssertTrue(host.isOn(diskID))
        XCTAssertEqual(settings.object(forKey: ModuleCenter.key(diskID)) as? Bool, true)
        XCTAssertEqual(host.switchIssues[diskID], "operation is still writing")
        XCTAssertTrue(host.changing.isEmpty)
    }
}
