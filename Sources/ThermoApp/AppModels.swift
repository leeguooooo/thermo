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
    typealias ConnectionsFactory = @MainActor (@escaping ()->Bool)->ConnectionsModel
    private let makeConnections:ConnectionsFactory
    private var storedConnections:ConnectionsModel?
    var connectionsLoaded:Bool {storedConnections != nil}
    var connectionsSampling:Bool {storedConnections?.samplingActive ?? false}
    var connections:ConnectionsModel {
        if let storedConnections{return storedConnections}
        let defaults=self.defaults
        let model=makeConnections {ModulePreferences.isEnabled(BuiltinModuleManifests.connections,in:defaults)}
        storedConnections=model;return model
    }
    func stopConnectionViews() {storedConnections?.retireVisibility()}
    func connectionsExitBlocker()->MainPage? {storedConnections?.busy.isEmpty == false ? .connections:nil}
    func prepareConnectionsStop() throws->BuiltinModules.FinishStop? {
        guard let model=storedConnections else{return nil}
        guard model.busy.isEmpty else{throw BuiltinModules.StopRefused(description:tr("Wait for the Bluetooth connection change before switching this feature off."))}
        model.stopFeature()
        return { [weak self] in
            await model.finishFeatureStop()
            if self?.storedConnections === model {self?.storedConnections=nil}
        }
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

    init(defaults: UserDefaults = .standard, makeApps: @escaping @MainActor () -> AppsFeatureModels = { AppsFeatureModels() }, makeSpace: @escaping SpaceFactory = { SpaceLensModel(enabled:$0) }, invalidateSpaceCache: @escaping @MainActor () -> Void = { SpaceLens.invalidateCache() }, makeBrowser: @escaping BrowserFactory = {ChromePagesModel(enabled:$0,app:$1,appMemoryKB:$2,gpuKB:$3)}, makeWorkspace: @escaping WorkspaceFactory = {TabWorkspaceModel(enabled:$0,app:$1)}, makeConnections:@escaping ConnectionsFactory = {ConnectionsModel(enabled:$0)}, makeDisk: @escaping () -> DiskModel = { DiskModel(retentionPreferences:.stored(in:.standard)) },
         makeMonitor: @escaping () -> Monitor = { Monitor(samplingAllowed: { ModulePreferences.isEnabled(BuiltinModuleManifests.performance, in: .standard) }) }) {
        self.makeConnections=makeConnections;self.makeDisk = makeDisk;self.makeApps=makeApps;self.makeSpace=makeSpace;self.invalidateSpaceCache=invalidateSpaceCache;self.makeBrowser=makeBrowser;self.makeWorkspace=makeWorkspace;self.defaults=defaults
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
    typealias BrowserFactory = @MainActor (@escaping ()->Bool,String,Int?,Int?)->ChromePagesModel
    typealias WorkspaceFactory = @MainActor (@escaping ()->Bool,String)->TabWorkspaceModel
    private let makeBrowser:BrowserFactory
    private let makeWorkspace:WorkspaceFactory
    private var browsers:[String:ChromePagesModel]=[:]
    private var workspaces:[String:TabWorkspaceModel]=[:]
    var browsersLoaded:Bool {!browsers.isEmpty || !workspaces.isEmpty}
    func workspace(_ app:String)->TabWorkspaceModel {
        if let model=workspaces[app]{return model}
        let defaults=self.defaults
        let model=makeWorkspace({ModulePreferences.isEnabled(BuiltinModuleManifests.browser,in:defaults)},app)
        workspaces[app]=model;return model
    }
    func browserExitBlocker()->MainPage? {
        if let model=browsers.values.first(where:{$0.closing != nil}) {return .browser(model.app)}
        if let model=workspaces.values.first(where:{$0.mutating || $0.work.hasOperations}) {return .browser(model.app)}
        if TabAutomation.current?.running == true {return .browser("Google Chrome")}
        return nil
    }
    func prepareBrowserStop() throws -> BuiltinModules.FinishStop? {
        guard browserExitBlocker()==nil else {
            throw BuiltinModules.StopRefused(description:tr("Wait for browser changes or tab grouping to finish before switching this feature off."))
        }
        TabAutomation.stopIfStarted()
        let checks=Array(browsers.values),spaces=Array(workspaces.values)
        for model in checks{model.stopFeature()}
        for model in spaces{model.stopFeature()}
        return { [weak self] in
            for model in checks{await model.finishFeatureStop()}
            for model in spaces{await model.finishFeatureStop()}
            self?.browsers=[:];self?.workspaces=[:]
        }
    }

    func stopBrowserChecks() {
        for model in browsers.values where model.running { model.stop() }
        for model in workspaces.values {model.retireRead()}
    }

    /// One pages model per browser, so its last result is still there when the page is reopened.
    func browser(_ app: String, memoryKB: Int? = nil, gpuKB: Int? = nil) -> ChromePagesModel {
        let defaults=self.defaults
        let m = browsers[app] ?? makeBrowser({ModulePreferences.isEnabled(BuiltinModuleManifests.browser,in:defaults)},app,memoryKB,gpuKB)
        if let memoryKB { m.appMemoryKB = memoryKB }
        if let gpuKB { m.gpuKB = gpuKB }
        browsers[app] = m
        return m
    }
}
