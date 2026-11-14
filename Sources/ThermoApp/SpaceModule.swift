import AppKit
import ModuleKit
import SwiftUI
import ThermoL10n

enum SpaceModule: BuiltinModule {
    static let manifest=BuiltinModuleManifests.space
    static let legacyMenuEntries:[String:String]=[:]
    @MainActor static var enabled:Bool {ModuleCenter.shared.isOn(manifest.id)}
    static func owns(_ page:MainPage)->Bool {
        if case .space=page{return true}
        if case let .module(id,_)=page{return id==manifest.id}
        return false
    }
    static func canonicalArgument(_ argument:String)->String {argument}
    static func target(_ scene:String)->MainPage? {
        if scene=="space"{return .space(.browse)}
        guard scene.hasPrefix("space:"),let tab=SpaceTab(rawValue:String(scene.dropFirst(6))) else{return nil}
        return .space(tab)
    }
    static func supports(_ entry:ModuleManifest.Entry)->Bool {entry.kind == .page && entry.scene.flatMap(target) != nil}
    @MainActor static func sidebar(section:BuiltinSidebarSection,page:Binding<MainPage>,models:AppModels,
                                  row:@escaping @MainActor (BuiltinSidebarItem)->AnyView)->AnyView {
        guard section == .storage,let entry=manifest.entries.first else{return AnyView(EmptyView())}
        let tab=page.wrappedValue.spaceTab ?? BuiltinModules.page(page.wrappedValue)?.target?.spaceTab ?? .browse
        return row(.init(entry:entry,target:.space(tab),tint:.cyan,selected:owns(page.wrappedValue)))
    }
    @MainActor static func page(_ entry:ModuleManifest.Entry,selection:Binding<MainPage>,models:AppModels)->AnyView {
        guard let tab=entry.scene.flatMap(target)?.spaceTab else{return AnyView(ModuleOffView())}
        return AnyView(SpacePage(model:models.space,tab:Binding(get:{selection.wrappedValue.spaceTab ?? tab},set:{selection.wrappedValue = .space($0)})))
    }
    @MainActor static func settings(_ entry:ModuleManifest.Entry,models:AppModels)->AnyView {AnyView(EmptyView())}
    @MainActor static func prepareStop(models:AppModels)throws->BuiltinModules.FinishStop? {try models.prepareSpaceStop()}
    @MainActor static func appearance(_ page:MainPage)->(glow:Bool,tint:Color?){(false,nil)}
    @MainActor static func prepareReview(_ arguments:[String],page:inout MainPage,models:AppModels){}
    @MainActor static func snapshotReady(_ arguments:[String],models:AppModels,started:Date)->Bool {
        models.space.tree != nil && !models.space.scanning && !models.space.findingDuplicates
    }
}
