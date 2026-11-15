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
    private let makeApps: @MainActor () -> AppsFeatureModels
    private let defaults: UserDefaults
    typealias SpaceFactory = @MainActor (@escaping () -> Bool) -> SpaceLensModel
    private let makeSpace: SpaceFactory
    private let invalidateSpaceCache: @MainActor () -> Void
    private var storedSpace: SpaceLensModel?
    private var spaceInvalidated = false
    var spaceLoaded: Bool { storedSpace != nil }
    var space: SpaceLensModel {
        if let storedSpace {return storedSpace}
        let defaults=self.defaults
        let created=makeSpace {ModulePreferences.isEnabled(BuiltinModuleManifests.space,in:defaults)}
        if spaceInvalidated {created.invalidateAfterRestore([created.root]);spaceInvalidated=false}
        storedSpace=created;return created
    }
    @discardableResult func revealInSpace(_ path:String)->Bool {
        guard ModulePreferences.isEnabled(BuiltinModuleManifests.space,in:defaults) else{return false}
        space.reveal(path);return true
    }
    func stopSpaceViews() {storedSpace?.stop();storedSpace?.stopDuplicates()}
    func invalidateSpaceAfterRestore(_ paths:[String]) {
        if let storedSpace {storedSpace.invalidateAfterRestore(paths)}
        else if !paths.isEmpty {spaceInvalidated=true;invalidateSpaceCache()}
    }
    func prepareSpaceStop() throws -> BuiltinModules.FinishStop? {
        guard let model=storedSpace else{return nil}
        guard model.canStopFeature else {
            throw BuiltinModules.StopRefused(description:tr("Wait for file removal or the current AI request before switching this feature off."))
        }
        model.stopFeature()
        return { [weak self] in
            await model.finishFeatureStop()
            if self?.storedSpace === model {self?.storedSpace=nil}
        }
    }
    private var storedApps: AppsFeatureModels?
    var appsLoaded: Bool { storedApps != nil }
    private var software: AppsFeatureModels {
        if let storedApps { return storedApps }
        let created=makeApps(),defaults=self.defaults
        created.setEnabled { ModulePreferences.isEnabled(BuiltinModuleManifests.apps,in:defaults) }
        storedApps=created;return created
    }
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

    init(defaults: UserDefaults = .standard, makeApps: @escaping @MainActor () -> AppsFeatureModels = { AppsFeatureModels() }, makeSpace: @escaping SpaceFactory = { SpaceLensModel(enabled:$0) }, invalidateSpaceCache: @escaping @MainActor () -> Void = { SpaceLens.invalidateCache() }, nativeDefinitions:[NativeFeatureDefinition]? = nil, makeAgents:@escaping AgentsFactory = {AgentScanner(enabled:$0)}, makeDisk: @escaping () -> DiskModel = { DiskModel(retentionPreferences:.stored(in:.standard)) },
         makeMonitor: @escaping () -> Monitor = { Monitor(samplingAllowed: { ModulePreferences.isEnabled(BuiltinModuleManifests.performance, in: .standard) }) }) {
        self.makeAgents=makeAgents;self.makeDisk = makeDisk;self.makeApps=makeApps;self.makeSpace=makeSpace;self.invalidateSpaceCache=invalidateSpaceCache;self.defaults=defaults
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
    var apps: AppsModel { get {software.apps} set {software.apps=newValue} }
    var startup: StartupItemsModel { software.startup }
    var softwareUpdates: AppUpdatesModel { software.updates }
    var nativeUpdates: NativeUpdatesModel { software.native }
    var appStore: AppStoreModel { software.store }
    func softwareExitBlocker() -> MainPage? { storedApps?.exitBlocker() }
    func retireSoftwareViews() { storedApps?.retireViews() }
    func invalidateAppsAfterRestore() { storedApps?.apps.invalidateAfterRestore() }
    func prepareNativeRecovery() {
        guard ModulePreferences.isEnabled(BuiltinModuleManifests.apps,in:defaults) else {return}
        software.updates.channel="native";software.native.showRecovery=true
    }
    func prepareAppsStop() throws -> BuiltinModules.FinishStop? {
        guard let session=storedApps else {return nil}
        guard session.beginStopping() else {
            throw BuiltinModules.StopRefused(description:tr("Wait for app removal, startup changes or updates before switching this feature off."))
        }
        return { [weak self] in
            await session.finishStopping()
            if self?.storedApps === session {self?.storedApps=nil}
        }
    }
}
