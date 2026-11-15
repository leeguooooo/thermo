import CoreAudio
import ModuleKit
import NativeFeatureAPI
import SwiftUI
import XCTest
@testable import ConnectionsFeature

@MainActor final class ConnectionsModuleLifecycleTests:XCTestCase {
    private func defaults()->UserDefaults {
        let name="thermo-connections-module-"+UUID().uuidString
        let settings=UserDefaults(suiteName:name)!
        addTeardownBlock {settings.removePersistentDomain(forName:name)}
        return settings
    }
    private func device()->BluetoothDevice {
        .init(name:"Fixture",address:"00:00:00:00:00:01",connected:false,kind:.other,levels:[],rssi:nil)
    }
    func testColdOffCannotStartTimerScanBluetoothDeviceOrSoundChanges() async {
        let model=ConnectionsModel(enabled:{false},wifiScanner:{XCTFail("off Wi-Fi scan");return []},connector:{_,_ in XCTFail("off connect");return false},bluetoothReader:{XCTFail("off Bluetooth read");return nil},computerModelResolver:{_ in XCTFail("off Bonjour");return .init()})
        model.start();model.setVisible(true,owner:UUID());model.scan();model.refreshBluetooth()
        model.setConnected(true,device());model.setVolume(0.5);model.toggleMute();model.requestNames()
        await model.work.finish()
        XCTAssertFalse(model.samplingActive);XCTAssertFalse(model.scanning);XCTAssertFalse(model.readingBluetooth)
        XCTAssertNil(model.bluetooth);XCTAssertNil(model.wifi);XCTAssertTrue(model.busy.isEmpty)
        XCTAssertEqual(model.nameAccess,.unknown)
    }
    func testStoppingDrainsPhysicalBluetoothAndRejectsItsLateReport() async {
        let entered=expectation(description:"Bluetooth read"),release=DispatchSemaphore(value:0)
        defer{release.signal()}
        let report=BluetoothReport(powerOn:true,devices:[device()])
        let model=ConnectionsModel(bluetoothReader:{entered.fulfill();_ = release.wait(timeout:.now()+5);return report})
        model.refreshBluetooth();await fulfillment(of:[entered],timeout:2)
        model.stopFeature()
        var drained=false;let finish=Task {await model.finishFeatureStop();drained=true}
        await Task.yield();XCTAssertFalse(drained)
        release.signal();await finish.value
        XCTAssertNil(model.bluetooth);XCTAssertFalse(model.readingBluetooth);XCTAssertEqual(model.work.count,0)
    }
    func testStoppingDrainsWiFiScanAndCannotPublishItsOldNetworks() async {
        let entered=expectation(description:"Wi-Fi scan"),release=DispatchSemaphore(value:0)
        defer{release.signal()}
        let model=ConnectionsModel(wifiScanner:{entered.fulfill();_ = release.wait(timeout:.now()+5);return [.init(id:"fixture",ssid:"Fixture",rssi:-40,channel:1,band:.ghz24,secure:true)]})
        model.scan();await fulfillment(of:[entered],timeout:2)
        model.stopFeature()
        var drained=false;let finish=Task {await model.finishFeatureStop();drained=true}
        await Task.yield();XCTAssertFalse(drained)
        release.signal();await finish.value
        XCTAssertNil(model.nearby);XCTAssertFalse(model.scanning)
    }
    func testCancellingQueuedBluetoothReadAllowsALaterRefreshWithoutPollingHardware() async {
        let entered=expectation(description:"replacement read")
        let model=ConnectionsModel(bluetoothReader:{entered.fulfill();return nil})
        model.refreshBluetooth();model.stop()
        await model.work.finish()
        XCTAssertFalse(model.readingBluetooth)
        model.refreshBluetooth();await fulfillment(of:[entered],timeout:2)
        await model.work.finish()
        XCTAssertFalse(model.readingBluetooth)
        model.stopFeature();await model.finishFeatureStop()
    }

}

@MainActor final class ConnectionsSessionTests:XCTestCase {
    private var manifest:ModuleManifest {BuiltinModuleManifests.connections}
    private func device()->BluetoothDevice {.init(name:"Fixture",address:"00:00:00:00:00:01",connected:false,kind:.other,levels:[],rssi:nil)}
    func testAcceptedDeviceChangeRefusesDisableAndQuitThroughNativeBoundary() async throws {
        let entered=expectation(description:"fake device change"),release=DispatchSemaphore(value:0);defer{release.signal()}
        let model=ConnectionsModel(connector:{_,_ in entered.fulfill();_ = release.wait(timeout:.now()+5);return true},connectionWait:{},bluetoothReader:{nil})
        let definition=NativeFeatureDefinition(manifest:manifest,makeSession:{availability in
            ConnectionsSession(availability:availability,makeModel:{gate in model.work.enabled=gate;return model})
        })
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in true}),route=NativeFeatureRoute(manifest.id,"home")
        XCTAssertNotNil(store.page(route));model.setConnected(true,device());await fulfillment(of:[entered],timeout:2)
        XCTAssertEqual(store.quitBlocker()?.route,route);XCTAssertThrowsError(try store.prepareStop(manifest.id));XCTAssertFalse(model.work.stopping)
        release.signal();await model.work.finish();XCTAssertNil(store.quitBlocker())
        if let drain=try store.prepareStop(manifest.id){await drain.finish()}
        XCTAssertFalse(store.status(manifest.id).modelLoaded)
    }
    func testColdOffInvalidRouteAndWindowRetirementNeverCreateModelAndReenableIsFresh() async throws {
        var enabled=false,models:[ConnectionsModel]=[]
        let definition=NativeFeatureDefinition(manifest:manifest,makeSession:{availability in
            ConnectionsSession(availability:availability,makeModel:{gate in
                let model=ConnectionsModel(enabled:gate,bluetoothReader:{nil});models.append(model);return model
            })
        })
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in enabled}),route=NativeFeatureRoute(manifest.id,"home")
        XCTAssertNil(store.page(route));store.retireVisibility();XCTAssertNil(store.quitBlocker());XCTAssertFalse(store.status(manifest.id).modelLoaded)
        enabled=true;XCTAssertNil(store.page(.init(manifest.id,"not-declared")));XCTAssertTrue(models.isEmpty)
        XCTAssertNotNil(store.page(route));let old=try XCTUnwrap(models.first)
        if let drain=try store.prepareStop(manifest.id){await drain.finish()}
        old.refreshBluetooth();XCTAssertEqual(old.work.count,0)
        XCTAssertNotNil(store.page(route));XCTAssertEqual(models.count,2);XCTAssertFalse(old === models[1])
        if let drain=try store.prepareStop(manifest.id){await drain.finish()}
    }
}
