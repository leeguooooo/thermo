import Foundation
import ModuleKit
import XCTest
@testable import ThermoApp

@MainActor final class ModuleCommandSwitchTests: XCTestCase {
    private func fixture() throws -> (URL,UserDefaults,String) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-command-switch-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let name="thermo-command-switch-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        addTeardownBlock{try? FileManager.default.removeItem(at:root);defaults.removePersistentDomain(forName:name)}
        return (root,defaults,name)
    }
    func testBlockingCommandRefusesTheSwitchWithoutChangingPreferencesOrRetiringModels() throws {
        let (root,defaults,_)=try fixture(),id=BuiltinModuleManifests.apps.id
        let lease=try ModuleCommandLease.begin(feature:id,home:root.path,enabled:{true})
        defer{withExtendedLifetime(lease) {}}
        var retired=0
        let center=ModuleCenter(defaults:defaults,prepareBuiltinStop:{_ in retired += 1;return nil},commandHome:root.path)
        center.setEnabled(id,false)
        XCTAssertTrue(center.isOn(id));XCTAssertEqual(retired,0)
        XCTAssertNotNil(center.switchIssues[id]);XCTAssertTrue(center.changing.isEmpty)
        XCTAssertFalse(lease.stopRequested)
    }
    func testWatchKeepsStoppingStateUntilItsActualReaderLeaseIsReleased() async throws {
        let (root,defaults,_)=try fixture(),id=BuiltinModuleManifests.performance.id
        var lease:ModuleCommandLease?=try ModuleCommandLease.begin(feature:id,interruptible:true,home:root.path,enabled:{true})
        let previous=MainWindow.state.page;defer{MainWindow.state.page=previous}
        let center=ModuleCenter(defaults:defaults,prepareBuiltinStop:{_ in nil},commandHome:root.path)
        center.setEnabled(id,false)
        XCTAssertFalse(center.isOn(id));XCTAssertTrue(center.changing.contains(id))
        XCTAssertEqual(lease?.stopRequested,true)
        XCTAssertThrowsError(try ModuleCommandLease.begin(feature:id,home:root.path,enabled:{true}))
        await Task.yield();XCTAssertTrue(center.changing.contains(id))
        lease=nil
        for _ in 0..<100 where center.changing.contains(id) {try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertFalse(center.changing.contains(id))
        center.setEnabled(id,true)
        XCTAssertTrue(center.isOn(id))
        let next=try ModuleCommandLease.begin(feature:id,home:root.path,enabled:{true})
        XCTAssertFalse(next.stopRequested)
    }
    func testOwnRefusalReleasesTheExternalAdmissionLock() throws {
        let (root,defaults,_)=try fixture(),id=BuiltinModuleManifests.space.id
        let center=ModuleCenter(defaults:defaults,prepareBuiltinStop:{_ in throw NativeModules.StopRefused(description:"owned action in progress")},commandHome:root.path)
        center.setEnabled(id,false)
        XCTAssertTrue(center.isOn(id));XCTAssertTrue(center.changing.isEmpty)
        let next=try ModuleCommandLease.begin(feature:id,home:root.path,enabled:{true})
        XCTAssertFalse(next.stopRequested)
    }
}
