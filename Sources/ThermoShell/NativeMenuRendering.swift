import AppKit
import NativeFeatureAPI
import SwiftUI

@MainActor struct NativeMenuRows:View {
    let nodes:[NativeMenuNode]
    var body:some View {
        ForEach(Array(nodes.enumerated()),id:\.offset){_,node in
            switch node {
            case let .action(action):
                Button{action.perform()} label:{title(action.title,symbol:action.symbol)}.disabled(!action.enabled)
            case let .submenu(name,symbol,items):
                Menu{NativeMenuRows(nodes:items)} label:{title(name,symbol:symbol)}
            case .separator:Divider()
            }
        }
    }
    @ViewBuilder private func title(_ text:String,symbol:String?)->some View {
        if let symbol{Label(text,systemImage:symbol)}else{Text(text)}
    }
}

/// NSMenuItem.target is weak; its represented object retains the exact frozen action.
@MainActor final class NativeMenuActionTarget:NSObject {
    let action:NativeMenuAction
    let owner:NativeUIEntryRef?
    init(action:NativeMenuAction,owner:NativeUIEntryRef?){self.action=action;self.owner=owner}
    @objc func invoke(_ sender:NSMenuItem){action.perform()}
}
@MainActor enum NativeMenuRendering {
    static func append(to menu:NSMenu,nodes:[NativeMenuNode],owner:NativeUIEntryRef? = nil) {
        menu.autoenablesItems=false
        for node in nodes {
            switch node {
            case let .action(action):
                let target=NativeMenuActionTarget(action:action,owner:owner)
                let item=NSMenuItem(title:action.title,action:#selector(NativeMenuActionTarget.invoke(_:)),keyEquivalent:"")
                item.target=target;item.representedObject=target;item.isEnabled=action.enabled
                item.image=image(action.symbol,title:action.title);menu.addItem(item)
            case let .submenu(title,symbol,items):
                let child=NSMenu(title:title);append(to:child,nodes:items,owner:owner)
                let item=NSMenuItem(title:title,action:nil,keyEquivalent:"");item.submenu=child;item.representedObject=owner
                item.image=image(symbol,title:title);menu.addItem(item)
            case .separator:
                let item=NSMenuItem.separator();item.representedObject=owner;menu.addItem(item)
            }
        }
    }
    private static func image(_ name:String?,title:String)->NSImage? {
        guard let name,let image=NSImage(systemSymbolName:name,accessibilityDescription:title) else{return nil}
        image.size=NSSize(width:16,height:16);return image
    }
}

@MainActor struct NativeFeatureMenuView:View {
    let ref:NativeUIEntryRef
    let placement:NativeMenuPlacement
    @ObservedObject private var modules=ModuleCenter.shared
    var body:some View {
        if modules.isOn(ref.module),let content=ShellState.shared.nativeFeatures.menuContent(ref) {
            content.view(placement,renderer:.init{AnyView(NativeMenuRows(nodes:$0))})
        }
    }
}
