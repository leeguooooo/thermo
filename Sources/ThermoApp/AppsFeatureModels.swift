import Foundation

/// One feature owns the software inventory, startup controls and update transactions.
@MainActor final class AppsFeatureModels {
    var apps: AppsModel { didSet { apps.work.enabled = enabled } }
    let startup: StartupItemsModel
    let updates: AppUpdatesModel
    let native: NativeUpdatesModel
    let store: AppStoreModel
    private var enabled: () -> Bool = { true }

    init(apps: AppsModel? = nil, startup: StartupItemsModel? = nil, updates: AppUpdatesModel? = nil,
         native: NativeUpdatesModel? = nil, store: AppStoreModel? = nil) {
        self.apps=apps ?? AppsModel();self.startup=startup ?? StartupItemsModel()
        self.updates=updates ?? AppUpdatesModel();self.native=native ?? NativeUpdatesModel()
        self.store=store ?? AppStoreModel()
        let native=self.native,updates=self.updates
        updates.otherUpdateInProgress = { [weak native] in native?.installing ?? false }
        native.otherUpdateInProgress = { [weak updates] in updates?.working ?? false }
    }
    func setEnabled(_ enabled: @escaping () -> Bool) {
        self.enabled=enabled
        for work in [apps.work,startup.work,updates.work,native.work,store.work] {work.enabled=enabled}
    }
    func exitBlocker() -> MainPage? {
        if apps.working {apps.exitRequested=true;return .apps(.installed)}
        if startup.working {startup.exitRequested=true;return .apps(.startup)}
        if updates.working {updates.exitRequested=true;updates.channel="homebrew";return .apps(.updates)}
        if native.installing {native.exitRequested=true;updates.channel="native";return .apps(.updates)}
        return nil
    }
    func retireViews() {apps.retire();startup.retire();updates.retire();native.retire()}
    var busy: Bool { apps.working || startup.working || updates.working || native.installing }
    func beginStopping() -> Bool {
        guard !busy else {return false}
        apps.stopFeature();startup.stopFeature();updates.stopFeature();native.stopFeature();store.stopFeature()
        return true
    }
    func finishStopping() async {
        await apps.finishFeatureStop();await startup.finishFeatureStop();await updates.finishFeatureStop()
        await native.finishFeatureStop();await store.finishFeatureStop();AppLastUsed.clear()
    }
}
