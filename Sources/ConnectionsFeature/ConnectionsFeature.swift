import ModuleKit
import NativeFeatureAPI
import SwiftUI
import ThermoL10n

package enum ConnectionsFeature {
    package static func registration()->NativeFeatureDefinition {
        .init(manifest:BuiltinModuleManifests.connections,makeSession:{ConnectionsSession(availability:$0)})
    }
}
@MainActor final class ConnectionsSession:NativeFeatureSession {
    private let availability:FeatureAvailability
    private let makeModel:@MainActor (@escaping ()->Bool)->ConnectionsModel
    private var storedModel:ConnectionsModel?
    init(availability:FeatureAvailability,makeModel:@escaping @MainActor (@escaping ()->Bool)->ConnectionsModel = {ConnectionsModel(enabled:$0)}) {
        self.availability=availability;self.makeModel=makeModel
    }
    func page(_ route:NativeFeatureRoute,navigation:NativeNavigation)->AnyView? {
        let entry=route.entry
        guard availability.acceptsWork,entry=="home" else{return nil}
        if storedModel==nil {let availability=availability;storedModel=makeModel {availability.acceptsWork}}
        return storedModel.map{AnyView(ConnectionsPage(model:$0))}
    }
    var status:NativeFeatureStatus {
        .init(modelLoaded:storedModel != nil,sampling:storedModel?.samplingActive ?? false,
              snapshotReady:storedModel.map{!$0.readingBluetooth && ($0.bluetooth != nil || $0.bluetoothFailed)} ?? false)
    }
    func retireVisibility(){storedModel?.retireVisibility()}
    func quitBlocker()->NativeFeatureBlocker? {
        guard storedModel?.busy.isEmpty == false else{return nil}
        return .init(reason:tr("Wait for the Bluetooth connection change before switching this feature off."),route:.init(BuiltinModuleManifests.connections.id,"home"))
    }
    func prepareStop()throws->NativeFeatureDrain {
        guard let model=storedModel else{return .init(finish:{})}
        guard model.busy.isEmpty else{throw NativeFeatureBusy(tr("Wait for the Bluetooth connection change before switching this feature off."))}
        model.stopFeature()
        return .init { [weak self] in
            await model.finishFeatureStop()
            if self?.storedModel === model {self?.storedModel=nil}
        }
    }
}
