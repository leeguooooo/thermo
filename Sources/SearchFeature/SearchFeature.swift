import AppKit
import DocumentPreviewAPI
import ModuleKit
import NativeFeatureAPI
import SwiftUI
import ThermoL10n
import ThermoUI

package struct SearchShortcutResult:Sendable {
    package let label:String
    package let spotlightReleased:Bool
    package let confirmed:Bool
    package let issue:String?
}
@MainActor package protocol SearchApplicationAccess:AnyObject {
    func show(settings:Bool)->Bool
    func takeOverSpotlight()->SearchShortcutResult
    func giveBackSpotlight()->SearchShortcutResult
}
package struct SearchRegistration:Sendable {
    package let definition:NativeFeatureDefinition
    package let makeAccess:@MainActor @Sendable (NativeFeatureStore)->any SearchApplicationAccess
}
package enum SearchFeature {
    package static let previewWorkerID="dev.thermo.search-preview"
    package static func registration(preview:@escaping @MainActor @Sendable ()->any DocumentPreviewService)->SearchRegistration {
        makeRegistration(preview:preview)
    }
    static func makeRegistration(preview:@escaping @MainActor @Sendable ()->any DocumentPreviewService,
                                 makeModel:@escaping SearchSession.ModelFactory = {LocalSearchModel(module:BuiltinModuleManifests.search,enabled:$0)},
                                 makeShortcut:@escaping SearchShortcutAuthority.Factory = {LocalSearchShortcut(module:BuiltinModuleManifests.search,action:$0)}) -> SearchRegistration {
        let authority=SearchShortcutAuthority(makeShortcut:makeShortcut)
        let definition=NativeFeatureDefinition(manifest:BuiltinModuleManifests.search,privateWorkers:[previewWorkerID],makeSession:{availability in
            let session=SearchSession(availability:availability,authority:authority,makeModel:makeModel,preview:preview)
            authority.current=session;return session
        })
        return .init(definition:definition,makeAccess:{SearchAccess(store:$0,authority:authority)})
    }
}

/// Only shortcut ownership survives model generations, including failed release and off recovery.
final class SearchShortcutAuthority:@unchecked Sendable {
    typealias Factory = @MainActor (@escaping @MainActor ()->Void)->LocalSearchShortcut
    private let makeShortcut:Factory
    @MainActor weak var current:SearchSession?
    @MainActor private(set) var stored:LocalSearchShortcut?
    init(makeShortcut:@escaping Factory){self.makeShortcut=makeShortcut}
    @MainActor var shortcut:LocalSearchShortcut {
        if let stored{return stored}
        let value=makeShortcut{[weak self] in self?.current?.toggle()}
        stored=value;return value
    }
    @MainActor func clear(_ session:SearchSession){if current === session{current=nil}}
    @MainActor func result(confirmed:Bool,issue:String? = nil)->SearchShortcutResult {
        let value=shortcut
        return .init(label:value.binding?.label ?? "none",spotlightReleased:value.spotlightReleased,confirmed:confirmed,issue:issue ?? value.issue)
    }
}
@MainActor private final class SearchAccess:SearchApplicationAccess {
    let store:NativeFeatureStore
    let authority:SearchShortcutAuthority
    init(store:NativeFeatureStore,authority:SearchShortcutAuthority){self.store=store;self.authority=authority}
    func show(settings:Bool)->Bool {store.activate(.init(BuiltinModuleManifests.search.id,settings ? "settings":"search"))}
    func takeOverSpotlight()->SearchShortcutResult {
        guard store.admitUIEntryOwner(.init(BuiltinModuleManifests.search.id,"settings")),let current=authority.current else {
            return .init(label:"none",spotlightReleased:false,confirmed:false,issue:tr("This feature is switched off."))
        }
        return current.takeOverSpotlight()
    }
    func giveBackSpotlight()->SearchShortcutResult {
        let shortcut=authority.shortcut;shortcut.giveBackToSpotlight()
        return authority.result(confirmed:!shortcut.spotlightReleased)
    }
}

@MainActor final class SearchSession:NativeFeatureSession {
    typealias ModelFactory = @MainActor (@escaping ()->Bool)->LocalSearchModel
    let availability:FeatureAvailability
    private let authority:SearchShortcutAuthority
    private let makeModel:ModelFactory
    private let previewService:@MainActor ()->any DocumentPreviewService
    private(set) var storedModel:LocalSearchModel?
    private var storedPanel:LocalSearchPanel?
    private var storedPreview:(any DocumentPreviewPresentation)?
    init(availability:FeatureAvailability,authority:SearchShortcutAuthority,makeModel:@escaping ModelFactory,preview:@escaping @MainActor ()->any DocumentPreviewService) {
        self.availability=availability;self.authority=authority;self.makeModel=makeModel;self.previewService=preview
    }
    var model:LocalSearchModel {
        if let storedModel{return storedModel}
        let availability=availability,value=makeModel{availability.acceptsWork};storedModel=value;return value
    }
    private var preview:any DocumentPreviewPresentation {
        if let storedPreview{return storedPreview}
        let availability=availability,value=previewService().makePresentation(available:{availability.acceptsWork})
        storedPreview=value;return value
    }
    private var panel:LocalSearchPanel {
        if let storedPanel{return storedPanel}
        let value=LocalSearchPanel(model:model,shortcut:authority.shortcut,preview:preview);storedPanel=value;return value
    }
    func start(){guard availability.acceptsWork else{return};authority.shortcut.activate();model.start()}
    func toggle(){guard availability.acceptsWork else{return};panel.toggle()}
    @discardableResult func show(settings:Bool)->Bool {
        guard availability.acceptsWork else{return false};panel.show(settings:settings);return panel.window?.isVisible == true
    }
    func takeOverSpotlight()->SearchShortcutResult {
        guard availability.acceptsWork else{return .init(label:"none",spotlightReleased:false,confirmed:false,issue:tr("This feature is switched off."))}
        let shortcut=authority.shortcut;shortcut.takeOverSpotlight()
        return authority.result(confirmed:shortcut.binding?.sameGesture(LocalSearchShortcut.commandSpace) == true)
    }
    func activate(_ ref:NativeUIEntryRef,navigation:NativeNavigation)->Bool {
        guard ref.module==BuiltinModuleManifests.search.id,["search","settings"].contains(ref.entry) else{return false}
        return show(settings:ref.entry=="settings")
    }
    func ui(_ surface:NativeUISurface,navigation:NativeNavigation)->AnyView? {
        guard availability.acceptsWork else{return nil}
        switch surface {
        case let .inlineSettings(ref):
            guard ref == .init(BuiltinModuleManifests.search.id,"settings") else{return nil}
            return AnyView(HStack(spacing:Theme.Space.m){
                Image(systemName:"magnifyingglass").frame(width:22).foregroundStyle(Theme.textSecondary)
                Text(tr("Search apps and files")).font(Theme.body);Spacer()
                Button(tr("Open")){[weak self] in self?.show(settings:true)}.buttonStyle(PillButtonStyle()).controlSize(.small)
            }.padding(.horizontal,Theme.Space.m).padding(.vertical,8))
        case let .renderPreview(ref):
            guard ref == .init(BuiltinModuleManifests.search.id,"settings") else{return nil}
            model.start();model.query="th"
            return AnyView(LocalSearchView(model:model,shortcut:authority.shortcut))
        default:return nil
        }
    }
    func page(_ route:NativeFeatureRoute,navigation:NativeNavigation)->AnyView?{nil}
    var status:NativeFeatureStatus{.init(modelLoaded:storedModel != nil,sampling:storedModel.map{$0.indexing || $0.searching} == true,snapshotReady:storedModel != nil)}
    func retireVisibility(){}
    func quitBlocker()->NativeFeatureBlocker?{nil}
    func shutdown(){authority.stored?.shutdown();storedModel?.stop();storedPreview?.stop(ifCurrent:nil);storedPanel?.retire()}
    func prepareStop()throws->NativeFeatureDrain {
        guard storedModel?.presentingDialog != true else{throw NativeFeatureBusy(tr("Finish the current search dialog before switching this feature off."))}
        try authority.stored?.deactivate()
        let model=storedModel,preview=storedPreview
        model?.stop();preview?.stop(ifCurrent:nil);storedPanel?.retire()
        return .init{[self] in
            await model?.finishStopping();await preview?.finishStopping()
            storedModel=nil;storedPanel=nil;storedPreview=nil;authority.clear(self)
        }
    }
}
