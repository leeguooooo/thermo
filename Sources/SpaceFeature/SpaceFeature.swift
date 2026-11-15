import Foundation
import CleanKit
import ModuleKit
import NativeFeatureAPI
import SwiftUI
import ThermoL10n

package enum SpaceFeature {
    package static func registration(services:@escaping @MainActor @Sendable ()->any SpaceServices,cacheURL:@escaping @Sendable ()->URL = {SpaceLens.cacheURL})->NativeFeatureDefinition {
        let cold=SpaceColdInvalidation(cacheURL:cacheURL)
        return .init(manifest:BuiltinModuleManifests.space,pageContracts:[
            .init(entry:"browse",optionFields:[.init("path",kind:.text,required:false)],checkOptions:{values in
                if let value=values["path"] {
                    guard case let .text(path)=value,path.hasPrefix("/"),!path.contains("\0") else{throw NativeRouteError("Invalid folder path.")}
                }
            })
        ],resolveLegacyPage:{argument in
            guard argument=="space" || argument.hasPrefix("space:") else{return nil}
            let suffix=argument.hasPrefix("space:") ? String(argument.dropFirst(6)):""
            return route(SpaceTab(rawValue:suffix) ?? .browse)
        },invalidateColdState:{_ in cold.invalidate()},makeSession:{SpaceFeatureSession(availability:$0,services:services(),cold:cold,cacheURL:cacheURL)})
    }
    static func route(_ tab:SpaceTab)->NativeFeatureRoute {.init(BuiltinModuleManifests.space.id,tab.rawValue)}
}

/// One pending cache invalidation per registration, including periods with no live session.
/// Constructing the metadata only allocates this small ledger; cache access stays deferred.
final class SpaceColdInvalidation:@unchecked Sendable {
    private let lock=NSLock()
    private var pending=false
    private let clear:@Sendable ()->Void
    init(cacheURL:@escaping @Sendable ()->URL) {clear={_ = SpaceLens.invalidateCache(at:cacheURL())}}
    init(clear:@escaping @Sendable ()->Void){self.clear=clear}
    func invalidate(){lock.lock();pending=true;lock.unlock();clear()}
    func take()->Bool {lock.lock();defer{lock.unlock()};let value=pending;pending=false;return value}
}

@MainActor final class SpaceFeatureSession:NativeFeatureSession {
    typealias ModelFactory = @MainActor (@escaping ()->Bool,any SpaceServices,URL)->SpaceLensModel
    private let availability:FeatureAvailability
    private let services:any SpaceServices
    private let cold:SpaceColdInvalidation
    private let cacheURL:@Sendable ()->URL
    private let makeModel:ModelFactory
    private var storedModel:SpaceLensModel?
    init(availability:FeatureAvailability,services:any SpaceServices,cold:SpaceColdInvalidation,cacheURL:@escaping @Sendable ()->URL,
         makeModel:@escaping ModelFactory={SpaceLensModel(services:$1,enabled:$0,cache:$2)}) {
        self.availability=availability;self.services=services;self.cold=cold;self.cacheURL=cacheURL;self.makeModel=makeModel
    }
    var model:SpaceLensModel {
        if let storedModel{return storedModel}
        let availability=availability,made=makeModel({availability.acceptsWork},services,cacheURL())
        if cold.take(){made.invalidateAfterRestore([made.root])}
        storedModel=made;return made
    }
    func page(_ route:NativeFeatureRoute,navigation:NativeNavigation)->AnyView? {
        guard availability.acceptsWork,let tab=SpaceTab(rawValue:route.entry) else{return nil}
        return AnyView(SpacePage(model:model,tab:Binding(get:{tab},set:{_ = navigation.show(SpaceFeature.route($0))})))
    }
    func preparePresentation(_ route:NativeFeatureRoute,options:[String:NativeContextValue]) {
        guard availability.acceptsWork,route.entry=="browse",case let .text(path)?=options["path"] else{return}
        model.reveal(path)
    }
    var status:NativeFeatureStatus {.init(modelLoaded:storedModel != nil,sampling:storedModel.map{$0.scanning || $0.findingDuplicates} ?? false)}
    func retireVisibility(){storedModel?.stop();storedModel?.stopDuplicates()}
    func invalidateAfterRestore(_ paths:[String]) {
        guard !paths.isEmpty else{return}
        if let storedModel{storedModel.invalidateAfterRestore(paths)}else{cold.invalidate()}
    }
    func snapshotReady(_ route:NativeFeatureRoute,arguments:[String],started:Date)->Bool {
        guard let model=storedModel else{return false}
        return model.tree != nil && !model.scanning && !model.findingDuplicates
    }
    func quitBlocker()->NativeFeatureBlocker? {
        guard storedModel?.canStopFeature == false else{return nil}
        storedModel?.exitRequested=true
        return .init(reason:tr("Wait for file removal or the current AI request before switching this feature off."),route:SpaceFeature.route(.browse))
    }
    func prepareStop()throws->NativeFeatureDrain {
        guard let model=storedModel else{return .init{}}
        guard model.canStopFeature else{throw NativeFeatureBusy(tr("Wait for file removal or the current AI request before switching this feature off."))}
        model.stopFeature()
        return .init{[weak self] in await model.finishFeatureStop();if self?.storedModel === model {self?.storedModel=nil}}
    }
}
