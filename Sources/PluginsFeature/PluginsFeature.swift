import ModuleKit
import NativeFeatureAPI
import SwiftUI
import ThermoL10n

package enum PluginsFeature {
    package static func registration(navigate:@escaping @MainActor (NativeFeatureRoute)->Void)->NativeFeatureDefinition {
        .init(manifest:BuiltinModuleManifests.plugins,makeSession:{PluginsSession(availability:$0,navigate:navigate)})
    }
}
@MainActor final class PluginsSession:NativeFeatureSession {
    private let availability:FeatureAvailability
    private let navigate:(NativeFeatureRoute)->Void
    private let makeModel:@MainActor (@escaping ()->Bool)->PluginsModel
    private var storedModel:PluginsModel?
    init(availability:FeatureAvailability,navigate:@escaping (NativeFeatureRoute)->Void,
         makeModel:@escaping @MainActor (@escaping ()->Bool)->PluginsModel = {PluginsModel(enabled:$0)}) {
        self.availability=availability;self.navigate=navigate;self.makeModel=makeModel
    }
    func page(_ route:NativeFeatureRoute,navigation:NativeNavigation)->AnyView? {
        let entry=route.entry
        guard availability.acceptsWork,entry=="home" else{return nil}
        if storedModel==nil {let availability=availability;storedModel=makeModel{availability.acceptsWork}}
        guard let model=storedModel else{return nil}
        return AnyView(PluginsPage(model:model,openDiagnostics:{[availability,navigate] in guard availability.acceptsWork else{return};navigate(.init(BuiltinModuleManifests.agents.id,"plugins"))}))
    }
    var status:NativeFeatureStatus {.init(modelLoaded:storedModel != nil,snapshotReady:storedModel.map{$0.loaded && !$0.checkingUpdates} ?? false)}
    func retireVisibility() {}
    func quitBlocker()->NativeFeatureBlocker? {
        guard storedModel?.canStopFeature == false else{return nil}
        return .init(reason:tr("Wait for plugin installation or updates before switching this feature off."),route:.init(BuiltinModuleManifests.plugins.id,"home"))
    }
    func prepareStop()throws->NativeFeatureDrain {
        guard let model=storedModel else{return .init(finish:{})}
        guard model.canStopFeature else{throw NativeFeatureBusy(tr("Wait for plugin installation or updates before switching this feature off."))}
        model.stopFeature()
        return .init { [weak self] in
            await model.finishFeatureStop()
            if self?.storedModel === model {self?.storedModel=nil}
        }
    }
}
