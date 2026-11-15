import CaptureCore
import NativeFeatureAPI
import SwiftUI
import ThermoL10n

@MainActor enum CaptureMenuPresentation {
    static func content(workspace:CaptureWorkspace,available:@escaping ()->Bool)->NativeMenuContent {
        .init(items:{nodes(workspace:workspace,placement:$0,available:available)},view:{placement,renderer in
            AnyView(CaptureMenuObserver(workspace:workspace,shortcuts:workspace.shortcuts,placement:placement,renderer:renderer,available:available))
        })
    }
    static func nodes(workspace:CaptureWorkspace,placement:NativeMenuPlacement,available:@escaping ()->Bool)->[NativeMenuNode] {
        guard available(),workspace.enabled else{return []}
        let icons:[CaptureAction:String]=[.screenshot:"viewfinder",.pinClipboard:"pin",.openImage:"photo",.scrolling:"arrow.down.right.and.arrow.up.left",.recording:"record.circle",.recordingDrafts:"film.stack",.pinText:"text.quote",.pinLaTeX:"function",.pinGroups:"square.stack",.restorePin:"arrow.uturn.backward",.restoreMouseInteraction:"cursorarrow",.showPins:"eye",.hidePins:"eye.slash",.closePins:"xmark.circle",.saveSettings:"square.and.arrow.down",.shortcutSettings:"keyboard"]
        func action(_ value:CaptureAction,suffix:Bool = false)->NativeMenuNode {
            let title=tr(value.title)+(suffix ? workspace.shortcutSuffix(for:value):"")
            return .action(.init(title:title,symbol:placement == .application ? nil:icons[value],perform:{
                guard available(),workspace.enabled else{return}
                do{try workspace.perform(value)}catch{workspace.report(error)}
            }))
        }
        func configured()->[NativeMenuNode] {
            let entries=workspace.shortcuts.settings.entries.filter(\.appearsInMenu)
            guard !entries.isEmpty else{return []}
            return [.submenu(title:tr("Configured capture actions"),symbol:nil,items:entries.map{entry in
                let label=workspace.shortcuts.label(for:entry)
                let title=(entry.title.isEmpty ? tr(entry.action.title):entry.title)+(label.isEmpty ? "":"  "+label)
                return .action(.init(title:title,perform:{
                    guard available(),workspace.enabled else{return}
                    workspace.shortcuts.run(entry)
                    if workspace.shortcuts.issue != nil{workspace.showActionSettings()}
                }))
            })]
        }
        switch placement {
        case .application:
            return [.screenshot,.pinClipboard,.openImage,.scrolling,.recording,.recordingDrafts].map{action($0)}
        case .status:
            let capture=[action(.screenshot,suffix:true),action(.scrolling),action(.recording),action(.recordingDrafts),action(.openImage)]+configured()+[action(.saveSettings),action(.shortcutSettings)]
            let pins=[action(.pinClipboard,suffix:true),action(.pinText),action(.pinLaTeX),action(.pinGroups),action(.restorePin),action(.restoreMouseInteraction)]
            return [.submenu(title:tr("Capture & record"),symbol:nil,items:capture),.submenu(title:tr("Clipboard & pins"),symbol:nil,items:pins)]
        case .popover,.review:
            let more=[action(.scrolling),action(.pinText),action(.pinLaTeX)]+configured()+[.separator,action(.pinGroups),action(.restorePin),action(.restoreMouseInteraction),action(.showPins),action(.hidePins),action(.closePins)]
            return [action(.screenshot,suffix:true),action(.pinClipboard,suffix:true),action(.openImage),.separator,action(.recording),action(.recordingDrafts),.separator,.submenu(title:tr("More capture tools"),symbol:"ellipsis.circle",items:more),.separator,action(.saveSettings),action(.shortcutSettings)]
        }
    }
}
private struct CaptureMenuObserver:View {
    @ObservedObject var workspace:CaptureWorkspace
    @ObservedObject var shortcuts:CaptureShortcutModel
    let placement:NativeMenuPlacement
    let renderer:NativeMenuRenderer
    let available:()->Bool
    var body:some View {renderer(CaptureMenuPresentation.nodes(workspace:workspace,placement:placement,available:available))}
}
