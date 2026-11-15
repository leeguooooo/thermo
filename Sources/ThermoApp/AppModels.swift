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
    typealias HistoryFactory = @MainActor (@escaping ()->Bool)->HistoryModel
    private let makeHistory:HistoryFactory
    private var storedHistory:HistoryModel?
    var historyLoaded:Bool {storedHistory != nil}
    var history:HistoryModel {
        if let storedHistory{return storedHistory}
        let defaults=self.defaults
        let model=makeHistory {ModulePreferences.isEnabled(BuiltinModuleManifests.history,in:defaults)}
        storedHistory=model;return model
    }
    func prepareHistoryStop() throws->BuiltinModules.FinishStop? {
        guard let model=storedHistory else{return nil}
        guard !model.busy else{throw BuiltinModules.StopRefused(description:tr("Wait for file restoration before switching History off."))}
        model.stopFeature()
        return { [weak self] in
            await model.finishFeatureStop()
            if self?.storedHistory === model {self?.storedHistory=nil}
        }
    }
    typealias CheckupFactory = @MainActor (@escaping ()->Bool)->CheckupModel
    private let makeCheckup:CheckupFactory
    private var storedCheckup:CheckupModel?
    var checkupLoaded:Bool {storedCheckup != nil}
    var checkup:CheckupModel {
        if let storedCheckup{return storedCheckup}
        let defaults=self.defaults
        let model=makeCheckup {ModulePreferences.isEnabled(BuiltinModuleManifests.checkup,in:defaults)}
        storedCheckup=model;return model
    }
    func checkupExitBlocker()->MainPage? {storedCheckup?.canStopFeature == false ? .checkup:nil}
    func prepareCheckupStop() throws->BuiltinModules.FinishStop? {
        guard let model=storedCheckup else{return nil}
        guard model.canStopFeature else{throw BuiltinModules.StopRefused(description:tr("Wait for the current AI check-up request before switching this feature off."))}
        model.stopFeature()
        return { [weak self] in
            await model.finishFeatureStop()
            if self?.storedCheckup === model {self?.storedCheckup=nil}
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

    init(defaults: UserDefaults = .standard, makeApps: @escaping @MainActor () -> AppsFeatureModels = { AppsFeatureModels() }, makeSpace: @escaping SpaceFactory = { SpaceLensModel(enabled:$0) }, invalidateSpaceCache: @escaping @MainActor () -> Void = { SpaceLens.invalidateCache() }, makeBrowser: @escaping BrowserFactory = {ChromePagesModel(enabled:$0,app:$1,appMemoryKB:$2,gpuKB:$3)}, makeWorkspace: @escaping WorkspaceFactory = {TabWorkspaceModel(enabled:$0,app:$1)}, nativeDefinitions:[NativeFeatureDefinition]? = nil, makeHistory:@escaping HistoryFactory = {HistoryModel(enabled:$0)}, makeAgents:@escaping AgentsFactory = {AgentScanner(enabled:$0)}, makeClaudeAccounts:@escaping ClaudeAccountsFactory = {ClaudeAccountsModel(enabled:$0)}, makeClaudeCleanup:@escaping ClaudeCleanupFactory = {ClaudeCleanupModel(enabled:$0)}, makeDownload:@escaping DownloadFactory = {YunXDownloadModel(enabled:$0)}, makeDownloadSetup:@escaping DownloadSetupFactory = {YunXChromeUseSetup(enabled:$0)}, makeCheckup:@escaping CheckupFactory = {CheckupModel(enabled:$0)}, makeDisk: @escaping () -> DiskModel = { DiskModel(retentionPreferences:.stored(in:.standard)) },
         makeMonitor: @escaping () -> Monitor = { Monitor(samplingAllowed: { ModulePreferences.isEnabled(BuiltinModuleManifests.performance, in: .standard) }) }) {
        self.makeClaudeAccounts=makeClaudeAccounts;self.makeClaudeCleanup=makeClaudeCleanup;self.makeDownload=makeDownload;self.makeDownloadSetup=makeDownloadSetup;self.makeCheckup=makeCheckup;self.makeAgents=makeAgents;self.makeHistory=makeHistory;self.makeDisk = makeDisk;self.makeApps=makeApps;self.makeSpace=makeSpace;self.invalidateSpaceCache=invalidateSpaceCache;self.makeBrowser=makeBrowser;self.makeWorkspace=makeWorkspace;self.defaults=defaults
        self.makeMonitor = makeMonitor
        let definitions=nativeDefinitions ?? BuiltinNativeFeatures.registrations
        nativeFeatures=NativeFeatureStore(definitions:definitions,enabled:{id in
            guard let manifest=definitions.first(where:{$0.manifest.id==id})?.manifest else{return false}
            return ModulePreferences.isEnabled(manifest,in:defaults)
        })
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
    typealias DownloadFactory = @MainActor (@escaping ()->Bool)->YunXDownloadModel
    typealias DownloadSetupFactory = @MainActor (@escaping ()->Bool)->YunXChromeUseSetup
    private let makeDownload:DownloadFactory
    private let makeDownloadSetup:DownloadSetupFactory
    private var storedDownload:YunXDownloadModel?
    private var storedDownloadSetup:YunXChromeUseSetup?
    var downloadLoaded:Bool {storedDownload != nil}
    var downloadSetupLoaded:Bool {storedDownloadSetup != nil}
    var download:YunXDownloadModel {
        if let storedDownload{return storedDownload}
        let defaults=self.defaults
        let model=makeDownload {ModulePreferences.isEnabled(BuiltinModuleManifests.download,in:defaults)}
        storedDownload=model;return model
    }
    var downloadSetup:YunXChromeUseSetup {
        if let storedDownloadSetup{return storedDownloadSetup}
        let defaults=self.defaults
        let setup=makeDownloadSetup {ModulePreferences.isEnabled(BuiltinModuleManifests.download,in:defaults)}
        storedDownloadSetup=setup;return setup
    }
    func downloadExitBlocker()->MainPage? {
        storedDownload?.canStopFeature == false || storedDownloadSetup?.canStopFeature == false ? .yunx:nil
    }
    func shutdownDownloadIfLoaded(){storedDownload?.shutdown()}
    func prepareDownloadStop()throws->BuiltinModules.FinishStop? {
        guard storedDownload?.canStopFeature != false,storedDownloadSetup?.canStopFeature != false else{throw BuiltinModules.StopRefused(description:tr("Wait for downloads, sign-in or tool installation before switching this feature off."))}
        let model=storedDownload,setup=storedDownloadSetup
        model?.stopFeature();setup?.stopFeature();YunXClipboardPrompt.shared.stop()
        return { [weak self] in
            await model?.finishFeatureStop();await setup?.finishFeatureStop()
            if self?.storedDownload === model {self?.storedDownload=nil}
            if self?.storedDownloadSetup === setup {self?.storedDownloadSetup=nil}
        }
    }
    typealias ClaudeAccountsFactory = @MainActor (@escaping ()->Bool)->ClaudeAccountsModel
    typealias ClaudeCleanupFactory = @MainActor (@escaping ()->Bool)->ClaudeCleanupModel
    private let makeClaudeAccounts:ClaudeAccountsFactory
    private let makeClaudeCleanup:ClaudeCleanupFactory
    private var storedClaudeAccounts:ClaudeAccountsModel?
    private var storedClaudeCleanup:ClaudeCleanupModel?
    var claudeLoaded:Bool {storedClaudeAccounts != nil || storedClaudeCleanup != nil}
    var claudeAccounts:ClaudeAccountsModel {
        if let storedClaudeAccounts{return storedClaudeAccounts}
        let defaults=self.defaults
        let model=makeClaudeAccounts {ModulePreferences.isEnabled(BuiltinModuleManifests.claude,in:defaults)}
        storedClaudeAccounts=model;return model
    }
    var claudeCleanup:ClaudeCleanupModel {
        if let storedClaudeCleanup{return storedClaudeCleanup}
        let defaults=self.defaults
        let model=makeClaudeCleanup {ModulePreferences.isEnabled(BuiltinModuleManifests.claude,in:defaults)}
        storedClaudeCleanup=model;return model
    }
    var claudeSnapshotReady:Bool {storedClaudeAccounts?.loaded == true || (storedClaudeCleanup?.loaded == true && storedClaudeCleanup?.busy == false)}
    func claudeExitBlocker()->MainPage? {
        guard let cleanup=storedClaudeCleanup,!cleanup.canStopFeature else{return nil}
        return .claude(cleanup.privacyOperationRunning ? .privacy:.reset)
    }
    func prepareClaudeStop()throws->BuiltinModules.FinishStop? {
        guard storedClaudeAccounts != nil || storedClaudeCleanup != nil else{return nil}
        guard storedClaudeCleanup?.canStopFeature != false else{throw BuiltinModules.StopRefused(description:tr("Wait for Claude reset, recovery or privacy changes before switching this feature off."))}
        let accounts=storedClaudeAccounts,cleanup=storedClaudeCleanup
        accounts?.stopFeature();cleanup?.stopFeature()
        return { [weak self] in
            await accounts?.finishFeatureStop();await cleanup?.finishFeatureStop()
            if self?.storedClaudeAccounts === accounts {self?.storedClaudeAccounts=nil}
            if self?.storedClaudeCleanup === cleanup {self?.storedClaudeCleanup=nil}
        }
    }
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
