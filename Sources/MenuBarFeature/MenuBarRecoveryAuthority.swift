import AppKit
import HotkeyCore
import MenuBarCore
import NativeFeatureAPI
import SwiftUI
import ThermoL10n

/// Assertion handles and failed key leases have one owner from their first creation.
/// No manager, discovery, window or defaults read is needed to project existing recovery.
final class MenuBarRecoveryAuthority:@unchecked Sendable {
    typealias ControllerFactory = @MainActor ()->MenuBarSessionController
    typealias ShortcutFactory = @MainActor (@escaping @MainActor ()->Void,@escaping @MainActor ()->Void)->MenuBarShortcuts
    private let makeController:ControllerFactory
    private let makeShortcuts:ShortcutFactory
    @MainActor private(set) var storedController:MenuBarSessionController?
    @MainActor private(set) var storedShortcuts:MenuBarShortcuts?
    @MainActor private(set) weak var manager:MenuBarManager?
    @MainActor private(set) var state:MenuBarSessionController.State = .visible
    @MainActor private(set) var terminating=false
    init(makeController:@escaping ControllerFactory = {MenuBarSessionController {try NativeMenuBarSession(configuration:$0)}},
         makeShortcuts:@escaping ShortcutFactory = {toggle,restore in MenuBarShortcuts(defaults:.standard,toggle:toggle,restore:restore)}) {
        self.makeController=makeController;self.makeShortcuts=makeShortcuts
    }
    @MainActor func bind(_ manager:MenuBarManager){self.manager=manager}
    @MainActor func isCurrent(_ manager:MenuBarManager)->Bool {self.manager === manager}
    @MainActor func detach(_ manager:MenuBarManager){if self.manager === manager{self.manager=nil}}
    @MainActor var controller:MenuBarSessionController {
        if let storedController{return storedController}
        let value=makeController();storedController=value
        value.didChange={[weak self] state in
            guard let self else{return}
            self.receive(state)
        }
        return value
    }
    @MainActor func receive(_ state:MenuBarSessionController.State){
        self.state=state;manager?.receiveVisibilityState(state);reconcileKeys()
    }
    @MainActor var shortcuts:MenuBarShortcuts {
        if let storedShortcuts{return storedShortcuts}
        let value=makeShortcuts({[weak self] in
            guard let self,!self.terminating,let manager=self.manager,manager.featureOn,manager.enabled,!manager.sleeping,manager.hasHiddenAssignments else{return}
            manager.setReveal(manager.reveal == .collapsed ? .hidden:.collapsed)
        },{[weak self] in self?.restoreAll()})
        storedShortcuts=value;return value
    }
    @MainActor func reconcileKeys(){storedShortcuts?.setEligible(!terminating && (manager?.enabled == true || state != .visible))}
    @MainActor func restoreAll(){
        guard !terminating else{return}
        manager?.prepareRecovery()
        storedController?.restore()
        reconcileKeys()
    }
    @MainActor func shutdown(){
        guard !terminating else{return};terminating=true
        storedShortcuts?.shutdown();manager?.prepareRecovery();storedController?.restore()
    }
    @MainActor func retainedMenu()->NativeRetainedMenu? {
        guard !terminating,manager?.enabled == true || state != .visible else{return nil}
        // Projection stays cold; native work happens only in explicit existing-owner actions.
        let ref=NativeUIEntryRef(BuiltinModuleManifests.menuBar.id,"tools")
        return .init(owner:ref,content:.init(items:{[weak self] _ in self?.nodes() ?? []},view:{[weak self] _,renderer in renderer(self?.nodes() ?? [])}))
    }
    @MainActor private func nodes()->[NativeMenuNode] {
        guard !terminating else{return []}
        var result:[NativeMenuNode]=[]
        if let manager,manager.featureOn,manager.enabled,manager.hasHiddenAssignments {
            result.append(.action(.init(title:tr(manager.reveal == .collapsed ? "Show hidden group":"Collapse groups"),perform:{[weak self,weak manager] in
                guard let self,!self.terminating,let manager,self.isCurrent(manager),manager.featureOn else{return}
                manager.setReveal(manager.reveal == .collapsed ? .hidden:.collapsed)
            })))
        }
        if manager?.enabled == true || state != .visible {
            result.append(.action(.init(title:tr("Restore all icons"),perform:{[weak self] in self?.restoreAll()})))
        }
        return result
    }
}
