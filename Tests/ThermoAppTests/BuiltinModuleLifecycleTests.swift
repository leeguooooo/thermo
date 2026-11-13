import AgentCore
import CleanKit
import ModuleHost
import ModuleKit
import XCTest
@testable import ThermoApp

@MainActor final class BuiltinModuleLifecycleTests: XCTestCase {
    let diskID = BuiltinModules.disk.id
    func defaults() -> (UserDefaults, String) {
        let name = "thermo-builtin-stop-" + UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }
    func center(_ defaults: UserDefaults, models: AppModels) -> ModuleCenter {
        ModuleCenter(defaults: defaults, prepareBuiltinStop: { _ in try models.prepareDiskStop() })
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
        let models = AppModels(makeDisk: { made += 1; return DiskModel(requestNotifications: {}) })
        let host = center(settings, models: models)
        host.setEnabled(diskID, false)
        XCTAssertFalse(host.isOn(diskID))
        XCTAssertFalse(models.diskLoaded)
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
        let models = AppModels(makeDisk: { DiskModel(scanIO: io, requestNotifications: {}) })
        let host = center(settings, models: models)
        var held: DiskModel? = models.disk
        weak var previous = held
        held!.scan()
        await fulfillment(of: [began], timeout: 2)
        host.setEnabled(diskID, false)
        XCTAssertFalse(host.isOn(diskID))
        XCTAssertTrue(host.changing.contains(diskID))
        XCTAssertTrue(models.diskLoaded, "The draining worker still owns this model")
        await fulfillment(of: [cancelled], timeout: 2)
        host.setEnabled(diskID, true)
        XCTAssertFalse(host.isOn(diskID), "Re-enable must wait for the old worker")
        release.signal()
        await eventually { !host.changing.contains(self.diskID) }
        XCTAssertFalse(models.diskLoaded)
        held!.scan(); held!.loadSaved(scanIfMissing: true)
        XCTAssertFalse(held!.scanning)
        XCTAssertFalse(held!.loadingSaved)
        host.setEnabled(diskID, true)
        let fresh = models.disk
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
        let models = AppModels(makeDisk: { DiskModel(scanIO: io, requestNotifications: {}) })
        let host = center(settings, models: models)
        models.disk.loadSaved(scanIfMissing: true)
        await fulfillment(of: [began], timeout: 2)
        host.setEnabled(diskID, false)
        XCTAssertTrue(host.changing.contains(diskID))
        release.signal()
        await eventually { !host.changing.contains(self.diskID) }
        XCTAssertFalse(models.diskLoaded)
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
