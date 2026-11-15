@testable import ThermoKernel
import AppKit
import CleanKit
import ModuleKit
import XCTest
@testable import ThermoShell
@testable import ThermoComposition

@MainActor final class PerformanceModuleTests: ThermoCompositionTestCase {
    func testRegisteredPagesKeepLegacyRoutesAndOwnTheirNavigationKeys() {
        XCTAssertTrue(NativeModules.problems.isEmpty, NativeModules.problems.joined(separator: "\n"))
        XCTAssertTrue(ModuleNavigation.conflicts(NativeModules.all).isEmpty)
        for (name, page) in [("overview",MainPage.overview),("sensors",.sensors),("fans",.fans),("memory",.memory),("cpu",.compute(false)),("gpu",.compute(true))] {
            let canonical=MainPage.native(.init(BuiltinModuleManifests.performance.id,name))
            XCTAssertEqual(MainPage(argument:name),canonical)
            XCTAssertEqual(MainPage(argument:name)?.nativeRoute,page.nativeRoute)
            XCTAssertEqual(page.module,BuiltinModuleManifests.performance.id)
            XCTAssertEqual(NativeModules.page(page)?.target,page)
            let generic=MainPage(argument:"module:"+BuiltinModuleManifests.performance.id+":"+name)
            XCTAssertEqual(generic.flatMap {NativeModules.page($0)?.target},page)
            XCTAssertFalse(HostPageSpecification.pages.contains {$0.argument == name})
        }
        XCTAssertEqual(BuiltinModuleManifests.performance.launch,.always)

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
        center.setEnabled(BuiltinModuleManifests.performance.id,false)
        XCTAssertFalse(center.shows(.overview) || center.shows(.sensors) || center.shows(.fans) || center.shows(.memory))
        XCTAssertNil(center.navigationKey(.overview))
        XCTAssertEqual(MainWindow.state.page,.settings)
        XCTAssertTrue(center.shows(.settings) && center.shows(.native(.init(BuiltinModuleManifests.connections.id,"home"))))
    }

    func testStopIsRefusedWhileHelperMaintenanceIsRunning() async {
        let services=AppSystemServices(helperInteraction:false,samplingAllowed:{false})
        let monitor=SystemPresentation(services:services)
        let entered=expectation(description:"isolated maintenance entered"),finished=expectation(description:"maintenance finished")
        let release=DispatchSemaphore(value:0)
        defer {release.signal();monitor.stopSetup()}
        (monitor.administration as! CoreHelperAdministration).performInstallation(operation:{entered.fulfill();_ = release.wait(timeout:.now()+5)},finished:{finished.fulfill()})
        await fulfillment(of:[entered],timeout:2)
        XCTAssertFalse(monitor.administration.latest.canRetirePerformance)
        let models=ShellState(services:services,makeSystemPresentation:{monitor})
        models.nativeFeatures.start(BuiltinModuleManifests.performance.id)
        XCTAssertThrowsError(try NativeModules.prepareStop(BuiltinModuleManifests.performance.id,models:models))
        release.signal();await fulfillment(of:[finished],timeout:2)
        XCTAssertFalse(monitor.installingHelper)
        // Retire any remaining helper-readiness polling after the isolated installer finishes.
        monitor.stopSetup()
        XCTAssertTrue(monitor.administration.latest.canRetirePerformance)
    }
}
