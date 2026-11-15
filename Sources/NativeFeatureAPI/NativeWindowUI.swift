import Foundation
import ModuleKit
import SwiftUI

/// Cached host facts; publishing visibility never admits an optional feature.
package struct NativeHostPresentation: Equatable, Sendable {
    package let windowVisible: Bool
    package let menuPanelVisible: Bool
    package let selection: NativeFeatureRoute?
    package init(windowVisible: Bool = false, menuPanelVisible: Bool = false, selection: NativeFeatureRoute? = nil) {
        self.windowVisible = windowVisible; self.menuPanelVisible = menuPanelVisible; self.selection = selection
    }
}

package enum NativeSidebarLocation:String,CaseIterable,Hashable,Sendable {
    case overview,machine,resources,storage,software,footer,agents
}
package struct NativeUIContributions:Sendable {
    package let sidebarLocations:Set<NativeSidebarLocation>
    package let hasOverlay:Bool
    package let hasBackdrop:Bool
    package let hasMenuContent:Bool
    package let compactPanelEntry:String?
    package init(sidebarLocations:Set<NativeSidebarLocation> = [],hasOverlay:Bool = false,hasBackdrop:Bool = false,hasMenuContent:Bool = false,compactPanelEntry:String? = nil) {
        self.sidebarLocations=sidebarLocations;self.hasOverlay=hasOverlay;self.hasBackdrop=hasBackdrop;self.hasMenuContent=hasMenuContent;self.compactPanelEntry=compactPanelEntry
    }
    package static let none=NativeUIContributions()
}
@MainActor package struct NativeSidebarContribution {
    package let route:NativeFeatureRoute
    package let tint:Color
    package let badge:Int
    package let trailing:String?
    package let trailingColor:Color?
    package let displayEntry:String?
    package init(route:NativeFeatureRoute,tint:Color,badge:Int = 0,trailing:String? = nil,trailingColor:Color? = nil,displayEntry:String? = nil){self.route=route;self.tint=tint;self.badge=badge;self.trailing=trailing;self.trailingColor=trailingColor;self.displayEntry=displayEntry}
}
@MainActor package struct NativeSidebarRow {
    package let route:NativeFeatureRoute
    package let manifest:ModuleManifest
    package let entry:ModuleManifest.Entry
    package let tint:Color
    package let badge:Int
    package let trailing:String?
    package let trailingColor:Color?
    package let selected:Bool
    package let open:@MainActor ()->Void
}
@MainActor package struct NativeSidebarRenderer {
    private let render:(NativeSidebarContribution)->AnyView
    init(render:@escaping (NativeSidebarContribution)->AnyView){self.render=render}
    package func callAsFunction(_ item:NativeSidebarContribution)->AnyView{render(item)}
}
@MainActor struct NativeSidebarHostRenderer {
    let render:(NativeSidebarRow)->AnyView
}
@MainActor package struct NativeSidebarGroup:Identifiable {
    package let id:String
    package let location:NativeSidebarLocation
    package let manifest:ModuleManifest
    let mount:(NativeSidebarHostRenderer)->AnyView
    /// Defer row construction until the actual sidebar owns its SwiftUI namespace/environment.
    package func content(row:@escaping @MainActor (NativeSidebarRow)->AnyView)->AnyView {
        mount(.init(render:row))
    }
}
package enum NativeUISurface {
    case sidebar(location:NativeSidebarLocation,selection:NativeFeatureRoute?,rows:NativeSidebarRenderer)
    case compactPanel(NativeFeatureRoute)
    case windowOverlay
    case inlineSettings(NativeUIEntryRef)
    case renderPreview(NativeUIEntryRef)
    case backdrop(NativeFeatureRoute)
}
@MainActor package struct NativeWindowUI {
    package let sidebar:[NativeSidebarGroup]
    package let overlay:AnyView
    package let backdrop:AnyView?
}
@MainActor struct NativeOverlayPart:Identifiable {
    let id:String
    let generation:UUID
    let view:AnyView
}
@MainActor struct NativeOverlays:View {
    let parts:[NativeOverlayPart]
    var body:some View {ForEach(parts){part in part.view.id(part.generation)}}
}
