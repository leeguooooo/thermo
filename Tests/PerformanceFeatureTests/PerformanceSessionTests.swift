import Foundation
import ModuleKit
import NativeFeatureAPI
import SystemServicesAPI
import XCTest
@testable import PerformanceFeature

@MainActor final class PerformanceSessionTests: XCTestCase {
    func testMetadataAndDisabledSurfacesNeverResolveServiceFactories() throws {
        let telemetry=PerformanceModelTests.Telemetry(),helper=PerformanceModelTests.Helper()
        var resolutions=0
        let definition=PerformanceFeature.registration(telemetry:{resolutions+=1;return telemetry},
            administration:{resolutions+=1;return helper},fanFactory:{resolutions+=1;return helper},showSettings:{})
        let catalog=try NativeFeatureCatalog(definitions:[definition])
        let store=NativeFeatureStore(catalog:catalog,enabled:{_ in false},navigation:.unavailable)
        let route=NativeFeatureRoute(BuiltinModuleManifests.performance.id,"overview")
        XCTAssertNil(store.page(route));XCTAssertNil(store.compactPanel(route));store.start(route.module)
        XCTAssertTrue(store.windowUI(selection:route,locations:Set(NativeSidebarLocation.allCases)).sidebar.isEmpty)
        XCTAssertFalse(store.status(route.module).modelLoaded)
        XCTAssertTrue(store.status(route.module).readers.isEmpty)
        XCTAssertEqual(resolutions,0);XCTAssertTrue(telemetry.leases.isEmpty);XCTAssertTrue(helper.clients.isEmpty)
    }
    func testColdDisabledSessionCanDrainWithoutCreatingAnyReader() async throws {
        let name="thermo-private-session-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        let telemetry=PerformanceModelTests.Telemetry(),helper=PerformanceModelTests.Helper()
        let session=PerformanceSession(availability:.init(enabled:{false}),telemetry:telemetry,administration:helper,fanFactory:helper,defaults:defaults,showSettings:{})
        session.start();session.hostPresentationChanged(.init(windowVisible:true,menuPanelVisible:true))
        XCTAssertFalse(session.status.modelLoaded || session.status.sampling)
        XCTAssertTrue(session.status.readers.isEmpty)
        let drain=try session.prepareStop();await drain.finish();session.start();session.shutdown()
        XCTAssertTrue(telemetry.leases.isEmpty);XCTAssertTrue(helper.clients.isEmpty)
        XCTAssertFalse(session.status.modelLoaded)
    }
    func testRepeatedStartSharesOneCoreLeaseAndRefusalKeepsTheSessionLive() async throws {
        let name="thermo-private-session-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        let telemetry=PerformanceModelTests.Telemetry(),helper=PerformanceModelTests.Helper()
        let session=PerformanceSession(availability:.init(enabled:{true}),telemetry:telemetry,administration:helper,fanFactory:helper,defaults:defaults,showSettings:{},
            makeRecorder:{PulseRecorder(readHistory:{[]},samplingAllowed:{false},readOnBattery:{false})})
        session.start();session.start()
        XCTAssertEqual(telemetry.leases.count,1);XCTAssertEqual(helper.clients.count,1)
        XCTAssertEqual(Set(session.status.readers.keys),["history"],"Starting history and sensors must not construct page-local readers")
        helper.value.installing=true
        XCTAssertThrowsError(try session.prepareStop());XCTAssertTrue(session.acceptsWork)
        helper.value.installing=false
        let drain=try session.prepareStop();await drain.finish()
        XCTAssertFalse(session.acceptsWork || session.status.sampling)
        XCTAssertEqual(telemetry.leases[0].finishes,1);XCTAssertEqual(helper.clients[0].finishes,1)
        session.start();XCTAssertEqual(telemetry.leases.count,1)
        XCTAssertEqual(helper.installs,0)
    }
}
