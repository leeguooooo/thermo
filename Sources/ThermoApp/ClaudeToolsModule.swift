import ModuleKit
import SwiftUI

enum ClaudeToolsModule:BuiltinModule {
    static let manifest=BuiltinModuleManifests.claude
    static let legacyMenuEntries:[String:String]=[:]
    static let sidebarSections:Set<BuiltinSidebarSection>=[.agents]
    @MainActor static var enabled:Bool {ModuleCenter.shared.isOn(manifest.id)}
    static func owns(_ page:MainPage)->Bool {
        if case .claude=page{return true}
        if case let .module(id,_)=page{return id==manifest.id}
        return false
    }
    static func canonicalArgument(_ argument:String)->String {argument}
    static func target(_ scene:String)->MainPage? {
        if scene=="claude"{return .claude(.accounts)}
        guard scene.hasPrefix("claude:"),let tab=ClaudeTab(rawValue:String(scene.dropFirst(7))) else{return nil}
        return .claude(tab)
    }
    static func supports(_ entry:ModuleManifest.Entry)->Bool {entry.kind == .page && entry.scene.flatMap(target) != nil}
    @MainActor static func sidebar(section:BuiltinSidebarSection,page:Binding<MainPage>,models:AppModels,row:@escaping @MainActor (BuiltinSidebarItem)->AnyView)->AnyView {
        guard section == .agents else{return AnyView(EmptyView())}
        return AnyView(ClaudeToolsSidebar(selection:page,row:row))
    }
    @MainActor static func page(_ entry:ModuleManifest.Entry,selection:Binding<MainPage>,models:AppModels)->AnyView {
        switch entry.scene.flatMap(target) {
        case .claude(.accounts):return AnyView(ClaudeAccountsPage(model:models.claudeAccounts))
        case let .claude(tab):return AnyView(ClaudeCleanupPage(model:models.claudeCleanup,tab:tab).id(tab))
        default:return AnyView(EmptyView())
        }
    }
    @MainActor static func settings(_ entry:ModuleManifest.Entry,models:AppModels)->AnyView {AnyView(EmptyView())}
    @MainActor static func prepareStop(models:AppModels)throws->BuiltinModules.FinishStop? {try models.prepareClaudeStop()}
    @MainActor static func appearance(_ page:MainPage)->(glow:Bool,tint:Color?){(false,nil)}
    @MainActor static func prepareReview(_ args:[String],page:inout MainPage,models:AppModels) {}
    @MainActor static func snapshotReady(_ args:[String],models:AppModels,started:Date)->Bool {
        models.claudeSnapshotReady
    }
}
private struct ClaudeToolsSidebar:View {
    @Binding var selection:MainPage
    let row:@MainActor (BuiltinSidebarItem)->AnyView
    var body:some View {
        ForEach(ClaudeToolsModule.manifest.entries.filter{$0.parent==nil || ClaudeToolsModule.owns(selection)},id:\.id) {entry in
            if let target=entry.scene.flatMap(ClaudeToolsModule.target) {
                row(.init(entry:entry,target:target,tint:.orange,selected:selection==target || BuiltinModules.page(selection)?.target==target))
            }
        }
    }
}
