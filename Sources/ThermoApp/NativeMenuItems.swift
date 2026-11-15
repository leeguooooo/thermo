import AppKit
import NativeFeatureAPI
import ThermoL10n

@MainActor enum NativeMenuItems {
    static func append(to menu:NSMenu,entries:[NativeMenuEntry],target:AnyObject,action:Selector,enabled:@escaping (String)->Bool,content:@escaping (NativeUIEntryRef)->NativeMenuContent? = {_ in nil}) {
        let section=NativeMenuSection(entries:entries,target:target,action:action,enabled:enabled,content:content)
        let anchor=NSMenuItem(title:"",action:nil,keyEquivalent:"");anchor.isHidden=true;anchor.representedObject=section
        menu.addItem(anchor);section.anchor=anchor;section.refresh(in:menu)
    }
    static func refreshContent(in menu:NSMenu) {
        let sections=menu.items.compactMap{$0.representedObject as? NativeMenuSection}
        for section in sections{section.refresh(in:menu)}
    }
    static func updateVisibility(in menu:NSMenu,enabled:(String)->Bool) {
        for item in menu.items {
            let ref=(item.representedObject as? NativeUIEntryRef) ?? (item.representedObject as? NativeMenuActionTarget)?.owner
            if let ref{item.isHidden = !enabled(ref.module)}
        }
    }
}
/// Refreshing the native section on menu open preserves flat app-menu actions without cold model IO.
@MainActor private final class NativeMenuSection {
    let entries:[NativeMenuEntry]
    weak var target:AnyObject?
    weak var anchor:NSMenuItem?
    let action:Selector
    let enabled:(String)->Bool
    let content:(NativeUIEntryRef)->NativeMenuContent?
    private let identifier=NSUserInterfaceItemIdentifier("thermo.native.section."+UUID().uuidString)
    init(entries:[NativeMenuEntry],target:AnyObject,action:Selector,enabled:@escaping (String)->Bool,content:@escaping (NativeUIEntryRef)->NativeMenuContent?) {
        self.entries=entries;self.target=target;self.action=action;self.enabled=enabled;self.content=content
    }
    func refresh(in menu:NSMenu) {
        guard let anchor,let target else{return}
        for item in menu.items where item.identifier==identifier{menu.removeItem(item)}
        guard let insertion=menu.items.firstIndex(where:{$0 === anchor}) else{return}
        let rendered=NSMenu()
        for entry in entries {
            if entry.hasContent {
                if enabled(entry.ref.module),let contribution=content(entry.ref){NativeMenuRendering.append(to:rendered,nodes:contribution.items(.application),owner:entry.ref)}
                continue
            }
            let item=rendered.addItem(withTitle:tr(entry.title),action:action,keyEquivalent:entry.shortcut)
            item.target=target;item.representedObject=entry.ref;item.keyEquivalentModifierMask=[.command,.shift];item.isHidden = !enabled(entry.ref.module)
        }
        for (offset,item) in rendered.items.enumerated() {
            rendered.removeItem(item);item.identifier=identifier;menu.insertItem(item,at:insertion+offset)
        }
    }
}
