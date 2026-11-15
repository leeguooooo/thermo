import Combine
import ModuleKit
import NativeFeatureAPI
import SystemServicesAPI
import ThermoKit
import XCTest
@testable import PerformanceFeature

@MainActor final class PerformanceModelTests: XCTestCase {
    final class Lease: TelemetrySamplingLease {
        var demands: [TelemetryDemand] = []
        var refreshes = 0, finishes = 0
        func setDemand(_ demand: TelemetryDemand) { demands.append(demand) }
        func refresh() { refreshes += 1 }
        func resetMenuBaselines() {}
        func beginStopping() {}
        func finishStopping() async { finishes += 1 }
    }
    final class Telemetry: TelemetryReadService {
        var value = TelemetryReading(), leases: [Lease] = []
        var latest: TelemetryReading { value }
        var readings: AnyPublisher<TelemetryReading,Never> { Empty().eraseToAnyPublisher() }
        var menuReadings: AnyPublisher<MenuTelemetryReading,Never> { Empty().eraseToAnyPublisher() }
        func dismissError() {}
        func refreshCurrent() {}
        func preferencesDidChange() {}
        func resetMenuBaselines() {}
        func beginPerformanceSampling(available: @escaping @MainActor () -> Bool) throws -> any TelemetrySamplingLease {
            XCTAssertTrue(available())
            let lease = Lease(); leases.append(lease); value.sampling = true; return lease
        }
    }
    final class Fan: FanPolicyAccess {
        let available: @MainActor () -> Bool
        var retired = false, refreshes = 0, requests = 0, finishes = 0
        init(_ available: @escaping @MainActor () -> Bool) { self.available = available }
        var latest: HelperReading { .init() }
        var readings: AnyPublisher<HelperReading,Never> { Empty().eraseToAnyPublisher() }
        func request(_ policy: FanPolicy, fans: [Int]) { if available() && !retired { requests += 1 } }
        func refreshObservation() { if available() && !retired { refreshes += 1 } }
        func beginRetiring() { retired = true }
        func finishRetiring() async { retired = true; finishes += 1 }
    }
    final class Helper: HelperAdministration, FanPolicyAccessFactory {
        var value = HelperReading(), clients: [Fan] = []
        var installs = 0, administrativeRefreshes = 0
        var latest: HelperReading { value }
        var readings: AnyPublisher<HelperReading,Never> { Empty().eraseToAnyPublisher() }
        func bind(available: @escaping @MainActor () -> Bool) -> any FanPolicyAccess {
            let client = Fan(available); clients.append(client); return client
        }
        func dismissError() {}
        func refresh() { administrativeRefreshes += 1 }
        func install() { installs += 1 }
        func installWithPassword() { installs += 1 }
        func uninstall(finished: @escaping @MainActor () -> Void) { finished() }
        func stopSetup() {}
        func setLidAwake(_ on: Bool) {}
        func openLoginItemsSettings() {}
        func restoreAutomaticFans(_ fans: [Int]) { XCTFail("Feature retirement must never reset fans") }
    }
    func testColdOffPresentationCannotAcquireSamplingOrHelperAuthority() async throws {
        let telemetry = Telemetry(), helper = Helper()
        let model = PerformanceModel(telemetry: telemetry, administration: helper, fanFactory: helper, available: { false })
        try model.start(); model.setHostPresentation(.init(windowVisible: true, menuPanelVisible: true))
        model.sampleNow(); model.refreshFanObservation(); model.installHelper(); model.setPolicy(.auto, fans: [0])
        await model.finishStopping()
        XCTAssertTrue(telemetry.leases.isEmpty); XCTAssertTrue(helper.clients.isEmpty)
        XCTAssertEqual(helper.installs, 0); XCTAssertEqual(helper.administrativeRefreshes, 0)
    }
    func testDemandOnlyFollowsPerformancePagesAndTheCompactPanel() async throws {
        let telemetry = Telemetry(), helper = Helper()
        let model = PerformanceModel(telemetry: telemetry, administration: helper, fanFactory: helper, available: { true })
        try model.start(); try model.start()
        let lease = try XCTUnwrap(telemetry.leases.first)
        XCTAssertEqual(telemetry.leases.count, 1); XCTAssertEqual(helper.clients.count, 1)
        model.setHostPresentation(.init(windowVisible: true, selection: .init("com.example.other", "home")))
        XCTAssertEqual(lease.demands.last?.visible, false)
        let sensors = NativeFeatureRoute(BuiltinModuleManifests.performance.id, "sensors")
        model.setHostPresentation(.init(windowVisible: true, selection: sensors))
        XCTAssertEqual(lease.demands.last, .init(visible: true, surface: .sensors))
        model.showUnnamedSensors(true)
        model.setHostPresentation(.init(windowVisible: true, menuPanelVisible: true, selection: sensors))
        XCTAssertEqual(lease.demands.last, .init(visible: true, surface: .overview, includeUnnamed: true))
        model.setHostPresentation(.init())
        XCTAssertEqual(lease.demands.last?.visible, false)
        XCTAssertEqual(helper.administrativeRefreshes, 0, "Visibility must use the revocable helper client")
        await model.finishStopping()
    }
    func testRetiredPresentationCannotReadOrControlTheReplacementSession() async throws {
        let telemetry = Telemetry(), helper = Helper()
        let old = PerformanceModel(telemetry: telemetry, administration: helper, fanFactory: helper, available: { true })
        try old.start(); await old.finishStopping()
        telemetry.value.model = "Replacement session"
        let fresh = PerformanceModel(telemetry: telemetry, administration: helper, fanFactory: helper, available: { true })
        try fresh.start()
        let client = try XCTUnwrap(helper.clients.last), refreshes = client.refreshes
        try old.start(); old.sampleNow(); old.refreshFanObservation(); old.installHelper(); old.setPolicy(.auto, fans: [0])
        XCTAssertEqual(telemetry.leases.count, 2)
        XCTAssertEqual(old.model, ""); XCTAssertEqual(fresh.model, "Replacement session")
        XCTAssertEqual(client.refreshes, refreshes); XCTAssertEqual(client.requests, 0); XCTAssertEqual(helper.installs, 0)
        XCTAssertEqual(telemetry.leases[0].finishes, 1); XCTAssertEqual(helper.clients[0].finishes, 1)
        await fresh.finishStopping()
    }
}
