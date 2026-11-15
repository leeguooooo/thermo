import ModuleKit
import NativeFeatureAPI
import SwiftUI
import ThermoL10n

package enum HistoryFeature {
    package static func registration(services: @escaping @MainActor () -> any HistoryServices) -> NativeFeatureDefinition {
        .init(manifest: BuiltinModuleManifests.history,ui:.init(sidebarLocations:[.footer]), resolveLegacyPage:{argument in argument=="history" || argument.hasPrefix("history:") ? .init(BuiltinModuleManifests.history.id,"home"):nil},makeSession: { HistorySession(availability: $0, services: services()) })
    }
}
@MainActor final class HistorySession: NativeFeatureSession {
    private let availability: FeatureAvailability
    private let services: any HistoryServices
    private let makeModel: @MainActor (@escaping () -> Bool, any HistoryServices) -> HistoryModel
    private var storedModel: HistoryModel?
    init(availability: FeatureAvailability, services: any HistoryServices,
         makeModel: @escaping @MainActor (@escaping () -> Bool, any HistoryServices) -> HistoryModel = { HistoryModel(enabled: $0, services: $1) }) {
        self.availability = availability; self.services = services; self.makeModel = makeModel
    }
    func ui(_ surface:NativeUISurface,navigation:NativeNavigation)->AnyView? {
        guard availability.acceptsWork,case let .sidebar(location,_,rows)=surface,location == .footer else{return nil}
        return AnyView(rows(.init(route:.init(BuiltinModuleManifests.history.id,"home"),tint:.brown)))
    }
    func page(_ route:NativeFeatureRoute,navigation:NativeNavigation) -> AnyView? {
        let entry=route.entry
        guard availability.acceptsWork, entry == "home" else { return nil }
        if storedModel == nil { let availability = availability; storedModel = makeModel({ availability.acceptsWork }, services) }
        guard let model = storedModel else { return nil }
        return AnyView(HistoryPage(model: model, services: services))
    }
    var status: NativeFeatureStatus { .init(modelLoaded: storedModel != nil, snapshotReady: storedModel?.loaded == true) }
    func retireVisibility() {}
    func quitBlocker() -> NativeFeatureBlocker? {
        guard storedModel?.busy == true else { return nil }
        return .init(reason: tr("Wait for file restoration before switching History off."), route: .init(BuiltinModuleManifests.history.id, "home"))
    }
    func prepareStop() throws -> NativeFeatureDrain {
        guard let model = storedModel else { return .init(finish: {}) }
        guard !model.busy else { throw NativeFeatureBusy(tr("Wait for file restoration before switching History off.")) }
        model.stopFeature()
        return .init { [weak self] in
            await model.finishFeatureStop()
            if self?.storedModel === model { self?.storedModel = nil }
        }
    }
}
