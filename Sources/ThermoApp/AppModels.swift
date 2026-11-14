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

    init(defaults: UserDefaults = .standard, makeApps: @escaping @MainActor () -> AppsFeatureModels = { AppsFeatureModels() }, makeSpace: @escaping SpaceFactory = { SpaceLensModel(enabled:$0) }, invalidateSpaceCache: @escaping @MainActor () -> Void = { SpaceLens.invalidateCache() }, makeDisk: @escaping () -> DiskModel = { DiskModel(retentionPreferences:.stored(in:.standard)) },
         makeMonitor: @escaping () -> Monitor = { Monitor(samplingAllowed: { ModulePreferences.isEnabled(BuiltinModuleManifests.performance, in: .standard) }) }) {
        self.makeDisk = makeDisk;self.makeApps=makeApps;self.makeSpace=makeSpace;self.invalidateSpaceCache=invalidateSpaceCache;self.defaults=defaults
        self.makeMonitor = makeMonitor
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
    lazy var agents = AgentScanner()
    var apps: AppsModel { get {software.apps} set {software.apps=newValue} }
    var startup: StartupItemsModel { software.startup }
    var softwareUpdates: AppUpdatesModel { software.updates }
    var nativeUpdates: NativeUpdatesModel { software.native }
    lazy var claudeCleanup = ClaudeCleanupModel()
    lazy var plugins = PluginsModel()
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
    private var browsers: [String: ChromePagesModel] = [:]

    func stopBrowserChecks() {
        for model in browsers.values where model.running { model.stop() }
    }

    /// One pages model per browser, so its last result is still there when the page is reopened.
    func browser(_ app: String, memoryKB: Int? = nil, gpuKB: Int? = nil) -> ChromePagesModel {
        let m = browsers[app] ?? ChromePagesModel(app: app, appMemoryKB: memoryKB, gpuKB: gpuKB)
        if let memoryKB { m.appMemoryKB = memoryKB }
        if let gpuKB { m.gpuKB = gpuKB }
        browsers[app] = m
        return m
    }
}
