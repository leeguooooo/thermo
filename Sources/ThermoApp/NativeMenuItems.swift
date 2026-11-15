import AppKit
import NativeFeatureAPI
import ThermoL10n

@MainActor enum NativeMenuItems {
    /// Keep off entries mounted so enabling a feature can reveal it without rebuilding the app menu.
    static func append(to menu:NSMenu,entries:[NativeMenuEntry],target:AnyObject,action:Selector,enabled:(String)->Bool) {
        for entry in entries {
            let item=menu.addItem(withTitle:tr(entry.title),action:action,keyEquivalent:entry.shortcut)
            item.target=target;item.representedObject=entry.ref;item.keyEquivalentModifierMask=[.command,.shift]
            item.isHidden = !enabled(entry.ref.module)
        }
    }
    static func updateVisibility(in menu:NSMenu,enabled:(String)->Bool) {
        for item in menu.items {
            if let ref=item.representedObject as? NativeUIEntryRef {item.isHidden = !enabled(ref.module)}
        }
    }
}
