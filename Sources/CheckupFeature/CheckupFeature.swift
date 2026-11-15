import ModuleKit
import NativeFeatureAPI
import SwiftUI
import ThermoKit
import ThermoL10n

package enum CheckupFeature {
    package static func registration(reading:@escaping @MainActor ()->Snapshot?,navigate:@escaping @MainActor (NativeFeatureRoute)->Void)->NativeFeatureDefinition {
        .init(manifest:BuiltinModuleManifests.checkup,makeSession:{CheckupSession(availability:$0,reading:reading,navigate:navigate)})
    }
}
@MainActor final class CheckupSession:NativeFeatureSession {
    private let availability:FeatureAvailability
    private let reading:()->Snapshot?
    private let navigate:(NativeFeatureRoute)->Void
    private let makeModel:@MainActor (@escaping ()->Bool)->CheckupModel
    private var storedModel:CheckupModel?
    init(availability:FeatureAvailability,reading:@escaping ()->Snapshot?,navigate:@escaping (NativeFeatureRoute)->Void,
         makeModel:@escaping @MainActor (@escaping ()->Bool)->CheckupModel = {CheckupModel(enabled:$0)}) {
        self.availability=availability;self.reading=reading;self.navigate=navigate;self.makeModel=makeModel
    }
    private var model:CheckupModel {
        if let storedModel{return storedModel}
        let availability=availability,model=makeModel {availability.acceptsWork};storedModel=model;return model
    }
    func page(_ route:NativeFeatureRoute,navigation:NativeNavigation)->AnyView? {
        let entry=route.entry
        guard availability.acceptsWork,entry=="home" else{return nil}
        return AnyView(CheckupPage(reading:reading,open:{[availability,navigate] route in guard availability.acceptsWork else{return};navigate(route)},model:model))
    }
    var status:NativeFeatureStatus {.init(modelLoaded:storedModel != nil,snapshotReady:storedModel != nil)}
    func retireVisibility() {}
    func quitBlocker()->NativeFeatureBlocker? {
        guard storedModel?.canStopFeature == false else{return nil}
        return .init(reason:tr("Wait for the current AI check-up request before switching this feature off."),route:.init(BuiltinModuleManifests.checkup.id,"home"))
    }
    func prepareReview(_ route:NativeFeatureRoute,arguments:[String]) {
        guard availability.acceptsWork,let index=arguments.firstIndex(of:"--fixture"),index+1<arguments.count else{return}
        model.loadFixture(answer:arguments[index+1])
    }
    func prepareStop()throws->NativeFeatureDrain {
        guard let model=storedModel else{return .init(finish:{})}
        guard model.canStopFeature else{throw NativeFeatureBusy(tr("Wait for the current AI check-up request before switching this feature off."))}
        model.stopFeature()
        return .init { [weak self] in
            await model.finishFeatureStop()
            if self?.storedModel === model {self?.storedModel=nil}
        }
    }
}
