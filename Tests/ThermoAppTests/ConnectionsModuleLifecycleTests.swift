import CoreAudio
import ModuleKit
import XCTest
@testable import ThermoApp

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
    func testRegistryOwnsLegacyAndGenericConnectionPage() {
        XCTAssertTrue(BuiltinModules.problems.isEmpty,BuiltinModules.problems.joined(separator:"\n"))
        XCTAssertEqual(MainPage.connections.module,ConnectionsModule.manifest.id)
        XCTAssertEqual(BuiltinModules.page(.connections)?.target,.connections)
        XCTAssertEqual(BuiltinModules.page(.module(ConnectionsModule.manifest.id,"home"))?.target,.connections)
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
    func testAcceptedDeviceChangeRefusesDisableAndQuitWithoutTouchingRealDevice() async throws {
        let entered=expectation(description:"fake device change"),release=DispatchSemaphore(value:0)
        defer{release.signal()}
        let model=ConnectionsModel(connector:{_,_ in entered.fulfill();_ = release.wait(timeout:.now()+5);return true},connectionWait:{},bluetoothReader:{nil})
        let models=AppModels(defaults:defaults(),makeConnections:{gate in model.work.enabled=gate;return model})
        _=models.connections
        model.setConnected(true,device());await fulfillment(of:[entered],timeout:2)
        XCTAssertEqual(models.connectionsExitBlocker(),.connections)
        XCTAssertThrowsError(try ConnectionsModule.prepareStop(models:models));XCTAssertFalse(model.work.stopping)
        release.signal();await model.work.finish()
        XCTAssertNil(models.connectionsExitBlocker())
        if let finish=try ConnectionsModule.prepareStop(models:models){await finish()}
        XCTAssertFalse(models.connectionsLoaded)
    }
    func testOffNavigationStatusAndWindowCloseDoNotCreateModelAndReenableIsFresh() async throws {
        let defaults=defaults();var creations=0
        let models=AppModels(defaults:defaults,makeConnections:{gate in creations += 1;return ConnectionsModel(enabled:gate,bluetoothReader:{nil})})
        let center=ModuleCenter(defaults:defaults,prepareBuiltinStop:{_ in try ConnectionsModule.prepareStop(models:models)})
        center.setEnabled(ConnectionsModule.manifest.id,false)
        XCTAssertFalse(center.shows(.connections));XCTAssertFalse(models.connectionsSampling)
        models.stopConnectionViews();XCTAssertNil(models.connectionsExitBlocker());XCTAssertEqual(creations,0)
        defaults.set(true,forKey:ModulePreferences.key(ConnectionsModule.manifest.id))
        let old=models.connections
        if let finish=try ConnectionsModule.prepareStop(models:models){await finish()}
        old.refreshBluetooth();XCTAssertEqual(old.work.count,0)
        let fresh=models.connections
        XCTAssertFalse(old === fresh);XCTAssertEqual(creations,2)
        if let finish=try ConnectionsModule.prepareStop(models:models){await finish()}
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
