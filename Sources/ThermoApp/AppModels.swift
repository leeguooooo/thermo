import NativeFeatureAPI
import AgentDoctor
import AppKit
import CleanKit
import Foundation
import ModuleKit

/// What the app keeps once: the menu bar panel and the main window show the same models.
@MainActor
final class AppModels {
    static let shared = AppModels()
    lazy var monitor = makeMonitor()
    private let makeMonitor: () -> Monitor
    private let defaults: UserDefaults
    let nativeFeatures:NativeFeatureStore
    lazy var updates = Updates()
    /// Whether disk cleanup's model exists. It is created on first use and never while the feature is off.
    private var storedDisk: DiskModel?
    private let makeDisk: () -> DiskModel
    var diskLoaded: Bool { storedDisk != nil }
    var disk: DiskModel {
        get {
            if let storedDisk { return storedDisk }
            let created = makeDisk(); storedDisk = created; return created
        }
        set { storedDisk = newValue }
    }

    init(defaults: UserDefaults = .standard, nativeDefinitions:[NativeFeatureDefinition]? = nil, makeAgents:@escaping AgentsFactory = {AgentScanner(enabled:$0)}, makeDisk: @escaping () -> DiskModel = { DiskModel(retentionPreferences:.stored(in:.standard)) },
         makeMonitor: @escaping () -> Monitor = { Monitor(samplingAllowed: { ModulePreferences.isEnabled(BuiltinModuleManifests.performance, in: .standard) }) }) {
        self.makeAgents=makeAgents;self.makeDisk = makeDisk;self.defaults=defaults
        self.makeMonitor = makeMonitor
        let catalog=nativeDefinitions.map{try! NativeFeatureCatalog(definitions:$0)} ?? BuiltinNativeFeatures.catalog
        nativeFeatures=NativeFeatureStore(catalog:catalog,enabled:{id in
            guard let manifest=catalog.manifest(id) else{return false}
            return ModulePreferences.isEnabled(manifest,in:defaults)
        },navigation:.init(show:{MainWindow.showNative($0)}))
    }

    func prepareDiskStop() throws -> BuiltinModules.FinishStop? {
        guard let model = storedDisk else { return nil }
        guard model.prepareToDisable() else {
            throw BuiltinModules.StopRefused(description: tr("Wait for cleanup or AI selection to finish before switching this feature off."))
        }
        return { [weak self] in
            await model.finishDisabling()
            if self?.storedDisk === model { self?.storedDisk = nil }
        }
    }
    typealias AgentsFactory = @MainActor (@escaping ()->Bool)->AgentScanner
    private let makeAgents:AgentsFactory
    private var storedAgents:AgentScanner?
    var agentsLoaded:Bool {storedAgents != nil}
    var existingAgents:AgentScanner? {storedAgents}
    var agentReport:DoctorReport? {storedAgents?.report}
    var agents:AgentScanner {
        if let storedAgents{return storedAgents}
        let defaults=self.defaults
        let scanner=makeAgents {ModulePreferences.isEnabled(BuiltinModuleManifests.agents,in:defaults)}
        storedAgents=scanner;return scanner
    }
    func agentsExitBlocker()->MainPage? {storedAgents?.canStopFeature == false ? .agents(.home):nil}
    func prepareAgentsStop() throws->BuiltinModules.FinishStop? {
        guard let scanner=storedAgents else{return nil}
        guard scanner.canStopFeature else{throw BuiltinModules.StopRefused(description:tr("Wait for the confirmed agent configuration changes before switching diagnostics off."))}
        scanner.stopFeature()
        return { [weak self] in
            await scanner.finishFeatureStop()
            if self?.storedAgents === scanner {self?.storedAgents=nil}
        }
    }
}
