@testable import ThermoKernel
import AppKit
import CleanKit
import ModuleKit
import XCTest
@testable import ThermoApp

@MainActor final class PerformanceModuleTests: XCTestCase {
    func testRegisteredPagesKeepLegacyRoutesAndOwnTheirNavigationKeys() {
        XCTAssertTrue(BuiltinModules.problems.isEmpty, BuiltinModules.problems.joined(separator: "\n"))
        XCTAssertTrue(ModuleNavigation.conflicts(BuiltinModules.all).isEmpty)
        for (name, page) in [("overview",MainPage.overview),("sensors",.sensors),("fans",.fans),("memory",.memory),("cpu",.compute(false)),("gpu",.compute(true))] {
            XCTAssertEqual(MainPage(argument:name),page)
            XCTAssertEqual(page.module,PerformanceModule.manifest.id)
            XCTAssertEqual(BuiltinModules.page(page)?.target,page)
            let generic=MainPage(argument:"module:"+PerformanceModule.manifest.id+":"+name)
            XCTAssertEqual(generic.flatMap {BuiltinModules.page($0)?.target},page)
            XCTAssertFalse(HostPageSpecification.pages.contains {$0.argument == name})
        }
        XCTAssertEqual(PerformanceModule.manifest.launch,.always)
        XCTAssertTrue(PerformanceModule.manifest.entries.allSatisfy(PerformanceModule.supports))
    }
    func testColdOffCannotRevivePageOrPanelSamplers() {
        let cpu=ComputeModel(samplingAllowed:{false}),memory=MemoryModel(samplingAllowed:{false})
        let pulse=SystemPulse(samplingAllowed:{false})
        var held=0,read=0
        let panel=PanelModel(readSample:{read += 1;return .init()},holdPulse:{held += 1},releasePulse:{held -= 1},samplingAllowed:{false})
        cpu.start();cpu.setVisible(true,owner:UUID());memory.start();memory.setVisible(true,owner:UUID());pulse.start();panel.setActive(true)
        XCTAssertFalse(cpu.samplingActive || memory.samplingActive || panel.samplingActive || pulse.samplingActive)
        XCTAssertEqual(held,0);XCTAssertEqual(read,0)
        XCTAssertFalse(pulse.sampled)
        pulse.stop();cpu.stop();memory.stop();panel.setActive(false)
    }
    func testSwitchingOffOverviewFallsBackToSettingsAndReleasesNavigation() {
        let name="thermo-performance-nav-"+UUID().uuidString
        let defaults=UserDefaults(suiteName:name)!
        defer { defaults.removePersistentDomain(forName:name) }
        let center=ModuleCenter(defaults:defaults,prepareBuiltinStop:{_ in nil})
        let previous=MainWindow.state.page
        defer { MainWindow.state.page=previous }
        MainWindow.state.page = .overview
        XCTAssertEqual(center.navigationKey(.overview),"1")
        center.setEnabled(PerformanceModule.manifest.id,false)
        XCTAssertFalse(center.shows(.overview) || center.shows(.sensors) || center.shows(.fans) || center.shows(.memory))
        XCTAssertNil(center.navigationKey(.overview))
        XCTAssertEqual(MainWindow.state.page,.settings)
        XCTAssertTrue(center.shows(.settings) && center.shows(.module(BuiltinModuleManifests.connections.id,"home")))
    }
    func testSensorStopCanDrainWithoutStartingOrContactingTheHelper() async {
        let monitor=Monitor(startMonitoring:false,helperInteraction:false,samplingAllowed:{false})
        monitor.startFeature();monitor.sampleNow()
        XCTAssertFalse(monitor.samplingActive)
        monitor.beginStoppingFeature();await monitor.finishStoppingFeature()
        XCTAssertNil(monitor.snapshot);XCTAssertNil(monitor.latest)
        XCTAssertTrue(monitor.canStopFeature)
    }
    func testStopIsRefusedWhileHelperMaintenanceIsRunning() async {
        let monitor=Monitor(startMonitoring:false,helperInteraction:false,samplingAllowed:{false})
        let entered=expectation(description:"isolated maintenance entered"),finished=expectation(description:"maintenance finished")
        let release=DispatchSemaphore(value:0)
        defer {release.signal();monitor.stopSetup()}
        monitor.services.helper.performInstallation(operation:{entered.fulfill();_ = release.wait(timeout:.now()+5)},finished:{finished.fulfill()})
        await fulfillment(of:[entered],timeout:2)
        XCTAssertFalse(monitor.canStopFeature)
        let models=AppModels(makeMonitor:{monitor})
        XCTAssertThrowsError(try PerformanceModule.prepareStop(models:models))
        release.signal();await fulfillment(of:[finished],timeout:2)
        XCTAssertFalse(monitor.installingHelper)
        // Retire any remaining helper-readiness polling after the isolated installer finishes.
        monitor.stopSetup()
        XCTAssertTrue(monitor.canStopFeature)
    }
}
