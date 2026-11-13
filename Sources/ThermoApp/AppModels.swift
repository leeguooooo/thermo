import AgentDoctor
import AppKit
import CleanKit
import Foundation

/// What the app keeps once: the menu bar panel and the main window show the same models.
@MainActor
final class AppModels {
    static let shared = AppModels()
    lazy var monitor = Monitor()
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

    init(makeDisk: @escaping () -> DiskModel = { DiskModel(retentionPreferences:.stored(in:.standard)) }) {
        self.makeDisk = makeDisk
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
    lazy var apps = AppsModel()
    lazy var startup = StartupItemsModel()
    lazy var softwareUpdates = AppUpdatesModel()
    lazy var nativeUpdates = NativeUpdatesModel()
    lazy var claudeCleanup = ClaudeCleanupModel()
    lazy var plugins = PluginsModel()
    lazy var appStore = AppStoreModel()
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
