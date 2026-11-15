import ModuleKit
import NativeFeatureAPI
import SwiftUI
import ThermoL10n

package enum AppsFeature {
    package static var registration:NativeFeatureDefinition {
        .init(manifest:BuiltinModuleManifests.apps,pageContracts:[
            .init(entry:"updates",optionFields:[.init("channel",kind:.text,required:false),.init("showRecovery",kind:.boolean,required:false)],checkOptions:{options in
                if case let .text(channel)?=options["channel"],!Set(["homebrew","native"]).contains(channel) {throw NativeRouteError("Unknown software update channel.")}
            })
        ],ui:.init(sidebarLocations:[.software]),resolveLegacyPage:{argument in
            guard argument=="apps" || argument.hasPrefix("apps:") else{return nil}
            let suffix=argument.hasPrefix("apps:") ? String(argument.dropFirst(5)):""
            let tab=suffix=="feeds" ? AppsTab.updates:AppsTab(rawValue:suffix) ?? .installed
            return route(tab)
        },makeSession:{AppsFeatureSession(availability:$0)})
    }
    static func route(_ tab:AppsTab)->NativeFeatureRoute {.init(BuiltinModuleManifests.apps.id,tab.rawValue)}
}

@MainActor final class AppsFeatureSession:NativeFeatureSession {
    private let availability:FeatureAvailability
    private let makeModels:@MainActor ()->AppsFeatureModels
    private var storedModels:AppsFeatureModels?
    init(availability:FeatureAvailability,makeModels:@escaping @MainActor ()->AppsFeatureModels={AppsFeatureModels()}) {
        self.availability=availability;self.makeModels=makeModels
    }
    var models:AppsFeatureModels {
        if let storedModels{return storedModels}
        let made=makeModels(),availability=availability
        made.setEnabled{availability.acceptsWork};storedModels=made;return made
    }
    func page(_ route:NativeFeatureRoute,navigation:NativeNavigation)->AnyView? {
        guard availability.acceptsWork,let tab=AppsTab(rawValue:route.entry) else{return nil}
        let models=models
        return AnyView(AppsPage(model:models.apps,startup:models.startup,updates:models.updates,native:models.native,store:models.store,
            tab:Binding(get:{tab},set:{_ = navigation.show(AppsFeature.route($0))})))
    }
    func ui(_ surface:NativeUISurface,navigation:NativeNavigation)->AnyView? {
        guard availability.acceptsWork,case let .sidebar(location,selection,rows)=surface,location == .software else{return nil}
        let target=selection.flatMap{$0.module==BuiltinModuleManifests.apps.id ? $0:nil} ?? AppsFeature.route(.installed)
        return AnyView(rows(.init(route:target,tint:.indigo,displayEntry:"installed")))
    }
    func preparePresentation(_ route:NativeFeatureRoute,options:[String:NativeContextValue]) {
        guard availability.acceptsWork,route.entry=="updates",!options.isEmpty else{return}
        if case let .text(channel)?=options["channel"] {models.updates.channel=channel}
        if case let .boolean(show)?=options["showRecovery"] {models.native.showRecovery=show}
    }
    func prepareReview(_ route:NativeFeatureRoute,arguments:[String]) {
        guard route.entry=="updates",let index=arguments.firstIndex(of:"--page"),index+1<arguments.count,arguments[index+1]=="apps:feeds" else{return}
        preparePresentation(route,options:["channel":.text("native")])
    }
    var status:NativeFeatureStatus {.init(modelLoaded:storedModels != nil)}
    func invalidateAfterRestore(_ paths:[String]) {if !paths.isEmpty {storedModels?.apps.invalidateAfterRestore()}}
    func retireVisibility(){storedModels?.retireViews()}
    func quitBlocker()->NativeFeatureBlocker? {
        storedModels?.exitBlocker().map{.init(reason:tr("Wait for app removal, startup changes or updates before switching this feature off."),route:AppsFeature.route($0))}
    }
    func snapshotReady(_ route:NativeFeatureRoute,arguments:[String],started:Date)->Bool {
        guard let models=storedModels,let tab=AppsTab(rawValue:route.entry) else{return false}
        switch tab {
        case .installed:return !models.apps.loading && !models.apps.apps.isEmpty
        case .leftovers:return models.apps.orphans != nil
        case .startup:return models.startup.report != nil && !models.startup.busy
        case .updates:return models.updates.channel=="native" ? models.native.loaded && !models.native.loading:models.updates.report != nil && !models.updates.busy
        case .store:return models.store.loaded
        }
    }
    func prepareStop()throws->NativeFeatureDrain {
        guard let models=storedModels else{return .init{}}
        guard models.beginStopping() else{throw NativeFeatureBusy(tr("Wait for app removal, startup changes or updates before switching this feature off."))}
        return .init{[weak self] in
            await models.finishStopping()
            if self?.storedModels === models {self?.storedModels=nil}
        }
    }
}
