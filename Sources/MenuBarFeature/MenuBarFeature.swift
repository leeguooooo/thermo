import AppKit
import ModuleKit
import NativeFeatureAPI
import SwiftUI
import ThermoL10n
import ThermoUI

package enum MenuBarFeature {
    package static func registration(closeHostMenuPanel:@escaping @MainActor @Sendable ()->Void)->NativeFeatureDefinition {
        registration(recovery:MenuBarRecoveryAuthority(),closeHostMenuPanel:closeHostMenuPanel)
    }
    static func registration(recovery:MenuBarRecoveryAuthority,closeHostMenuPanel:@escaping @MainActor @Sendable ()->Void = {},
                             makeManager:@escaping MenuBarFeatureSession.ManagerFactory = {availability,recovery in MenuBarManager(featureEnabled:{availability.acceptsWork},recovery:recovery)}) -> NativeFeatureDefinition {
        .init(manifest:BuiltinModuleManifests.menuBar,runsInBackground:true,retained:.init(menu:{recovery.retainedMenu()},shutdown:{recovery.shutdown()}),makeSession:{availability in
            MenuBarFeatureSession(availability:availability,recovery:recovery,makeManager:makeManager,closeHostMenuPanel:closeHostMenuPanel)
        })
    }
}
@MainActor final class MenuBarFeatureSession:NativeFeatureSession {
    typealias ManagerFactory = @MainActor (FeatureAvailability,MenuBarRecoveryAuthority)->MenuBarManager
    private let availability:FeatureAvailability
    private let recovery:MenuBarRecoveryAuthority
    private let makeManager:ManagerFactory
    private let closeHostMenuPanel:@MainActor ()->Void
    private(set) var storedManager:MenuBarManager?
    private var panel:MenuBarManagerPanel?
    init(availability:FeatureAvailability,recovery:MenuBarRecoveryAuthority,makeManager:@escaping ManagerFactory,closeHostMenuPanel:@escaping @MainActor ()->Void){self.availability=availability;self.recovery=recovery;self.makeManager=makeManager;self.closeHostMenuPanel=closeHostMenuPanel}
    private var manager:MenuBarManager {if let storedManager{return storedManager};let value=makeManager(availability,recovery);storedManager=value;return value}
    var status:NativeFeatureStatus{.init(modelLoaded:storedManager != nil,sampling:storedManager?.discoveryRunning == true)}
    func start(){guard availability.acceptsWork else{return};manager.start()}
    func page(_ route:NativeFeatureRoute,navigation:NativeNavigation)->AnyView?{nil}
    func retireVisibility(){}
    func quitBlocker()->NativeFeatureBlocker?{nil}
    func activate(_ ref:NativeUIEntryRef,navigation:NativeNavigation)->Bool {
        guard availability.acceptsWork,ref.module==BuiltinModuleManifests.menuBar.id,["tools","management"].contains(ref.entry) else{return false}
        if panel==nil{panel=MenuBarManagerPanel(model:manager,closeHostMenuPanel:closeHostMenuPanel)}
        panel?.show();return true
    }
    func ui(_ surface:NativeUISurface,navigation:NativeNavigation)->AnyView? {
        guard availability.acceptsWork else{return nil}
        switch surface {
        case let .inlineSettings(ref):
            guard ref == .init(BuiltinModuleManifests.menuBar.id,"management") else{return nil}
            return AnyView(HStack(spacing:Theme.Space.m){Image(systemName:"menubar.rectangle").frame(width:22).foregroundStyle(Theme.textSecondary);Text(tr("Manage menu bar")).font(Theme.body);Spacer();Button(tr("Open")){[weak self] in _=self?.activate(ref,navigation:.unavailable)}.buttonStyle(PillButtonStyle()).controlSize(.small)}.padding(.horizontal,Theme.Space.m).padding(.vertical,8))
        case let .renderPreview(ref):
            guard ref == .init(BuiltinModuleManifests.menuBar.id,"management") else{return nil}
            return AnyView(MenuBarManagerView(model:manager).frame(width:940,height:740))
        default:return nil
        }
    }
    func prepareStop()throws->NativeFeatureDrain {
        try storedManager?.stopFeature()
        panel?.close();panel=nil
        return .init{[self] in
            if let manager=storedManager{await manager.finishDiscovery();recovery.detach(manager)}
            storedManager=nil
        }
    }
    func shutdown(){panel?.close();panel=nil;storedManager?.shutdown();recovery.shutdown()}
}
