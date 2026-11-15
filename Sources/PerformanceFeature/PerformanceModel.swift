import Combine
import Foundation
import NativeFeatureAPI
import SystemServicesAPI
import ThermoKit
import ThermoL10n
import ModuleKit

/// Private presentation of the shared authorities. It never owns a sensor or helper transport.
@MainActor final class PerformanceModel: ObservableObject {
    private let telemetry: any TelemetryReadService
    private let administration: any HelperAdministration
    private let fanFactory: any FanPolicyAccessFactory
    private let available: @MainActor () -> Bool
    private var observations = Set<AnyCancellable>()
    private var sampling: (any TelemetrySamplingLease)?
    private var fan: (any FanPolicyAccess)?
    private var stopping = false
    private var host = NativeHostPresentation()
    private var unnamed = false
    private var lastHelperRefresh = Date.distantPast
    private var acceptsWork: Bool { !stopping && available() }
    private var frame: TelemetryReading { acceptsWork ? telemetry.latest : .init() }
    private var helper: HelperReading { acceptsWork ? administration.latest : .init() }

    init(telemetry: any TelemetryReadService, administration: any HelperAdministration,
         fanFactory: any FanPolicyAccessFactory, available: @escaping @MainActor () -> Bool) {
        self.telemetry = telemetry; self.administration = administration
        self.fanFactory = fanFactory; self.available = available
        telemetry.readings.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        administration.readings.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
    }
    var snapshot: Snapshot? { frame.snapshot }
    var latest: Snapshot? { frame.latestSnapshot }
    var sampledFans: [FanReading]? { frame.sampledFans }
    var fanReadingsUnavailable: Bool { frame.fanReadingsUnavailable }
    var stoppedFans: Set<Int> { frame.stoppedFans }
    var fanEmptyMessage: String { tr(fanReadingsUnavailable ? "Fan readings unavailable" : "Checking…") }
    var history: [HistoryPoint] { frame.history }
    var model: String { frame.model }
    var systemMemory: SystemStats.Memory? { frame.memory }
    var systemDisk: SystemStats.Disk? { frame.disk }
    var helperState: HelperState { helper.phase }
    var policies: [Int:FanPolicy] { helper.policies }
    var policiesAvailable: Bool { helper.policiesAvailable }
    var fanControlState: FanControlState? { helper.fanControl }
    var applyingPolicies: Bool { helper.applyingPolicies }
    var helperBusy: Bool { helper.busy }
    var settingUp: Bool { helper.settingUp }
    var setupStarted: Date? { helper.setupStarted }
    var pendingPolicies: [Int:FanPolicy] { helper.pendingPolicies }
    var usesSMAppService: Bool { helper.usesSMAppService }
    var lastError: String? {
        get { helper.error ?? frame.error }
        set {
            guard acceptsWork, newValue == nil else { return }
            administration.dismissError(); telemetry.dismissError()
        }
    }
    var samplingActive: Bool { sampling != nil && acceptsWork && telemetry.latest.sampling }
    var canStopFeature: Bool { administration.latest.canRetirePerformance }

    func start() throws {
        guard acceptsWork, sampling == nil else { return }
        sampling = try telemetry.beginPerformanceSampling(available: { [weak self] in self?.acceptsWork == true })
        fan = fanFactory.bind(available: { [weak self] in self?.acceptsWork == true })
        updateDemand(); refreshFanObservation()
    }
    func setHostPresentation(_ value: NativeHostPresentation) {
        guard acceptsWork else { return }
        let wasVisible = visible
        host = value; updateDemand()
        if visible && !wasVisible { sampleNow(); refreshFanObservation() }
    }
    private var selectedPerformancePage: String? {
        guard host.selection?.module == BuiltinModuleManifests.performance.id else { return nil }
        return host.selection?.entry
    }
    private var visible: Bool { host.menuPanelVisible || (host.windowVisible && selectedPerformancePage != nil) }
    private var surface: TelemetrySurface {
        if host.menuPanelVisible || selectedPerformancePage == "overview" { return .overview }
        return selectedPerformancePage == "sensors" ? .sensors : .compact
    }
    private func updateDemand() {
        guard acceptsWork else { return }
        sampling?.setDemand(.init(visible: visible, surface: surface, includeUnnamed: unnamed))
    }
    func showUnnamedSensors(_ value: Bool) { guard acceptsWork else { return }; unnamed = value; updateDemand(); sampleNow() }
    func sampleNow() { guard acceptsWork else { return }; sampling?.refresh() }
    func refreshFanObservation() {
        guard acceptsWork else { return }
        lastHelperRefresh = Date(); fan?.refreshObservation()
    }
    func refreshHelperIfNeeded(now: Date = Date()) {
        if visible, now.timeIntervalSince(lastHelperRefresh) >= 10 { refreshFanObservation() }
    }
    func setPolicy(_ policy: FanPolicy, fan: Int) { setPolicy(policy, fans: [fan]) }
    func setPolicy(_ policy: FanPolicy, fans: [Int]) { guard acceptsWork else { return }; fan?.request(policy, fans: fans) }
    func beginSetup() { guard acceptsWork else { return }; administration.install() }
    func installHelper() { beginSetup() }
    func installHelperWithPassword() { guard acceptsWork else { return }; administration.installWithPassword() }
    func stopSetup() { guard acceptsWork else { return }; administration.stopSetup() }
    func openLoginItemsSettings() { guard acceptsWork else { return }; administration.openLoginItemsSettings() }
    func beginStopping() {
        guard !stopping else { return }
        stopping = true; observations = []
        sampling?.beginStopping(); fan?.beginRetiring()
        objectWillChange.send()
    }
    func finishStopping() async {
        beginStopping()
        await sampling?.finishStopping(); await fan?.finishRetiring()
        sampling = nil; fan = nil
    }
}
