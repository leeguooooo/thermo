import ModuleKit
import SwiftUI

enum ClaudeToolsModule:BuiltinModule {
    static let manifest=BuiltinModuleManifests.claude
    static let legacyMenuEntries:[String:String]=[:]
    static let sidebarSections:Set<BuiltinSidebarSection>=[.agents]
    @MainActor static var enabled:Bool {ModuleCenter.shared.isOn(manifest.id)}
    static func owns(_ page:MainPage)->Bool {
        if case let .module(id,_)=page{return id==manifest.id}
        return false
    }
    static func canonicalArgument(_ argument:String)->String {
        if argument=="claude-cleanup" || argument.hasPrefix("claude-cleanup:") {return argument=="claude-cleanup:privacy" ? "claude:privacy":"claude:reset"}
        if argument=="claude" {return "claude:accounts"}
        if argument.hasPrefix("claude:") && !manifest.entries.contains(where:{$0.scene==argument}) {return "claude:accounts"}
        return argument
    }
    static func target(_ scene:String)->MainPage? {
        manifest.entries.first(where:{$0.scene==scene}).map{.module(manifest.id,$0.id)}
    }
    static func supports(_ entry:ModuleManifest.Entry)->Bool {entry.kind == .page && entry.scene.flatMap(target) != nil}
    @MainActor static func sidebar(section:BuiltinSidebarSection,page:Binding<MainPage>,models:AppModels,row:@escaping @MainActor (BuiltinSidebarItem)->AnyView)->AnyView {
        guard section == .agents else{return AnyView(EmptyView())}
        return AnyView(ClaudeToolsSidebar(selection:page,row:row))
    }
    @MainActor static func page(_ entry:ModuleManifest.Entry,selection:Binding<MainPage>,models:AppModels)->AnyView {
        models.nativeFeatures.page(.init(manifest.id,entry.id)) ?? AnyView(EmptyView())
    }
    @MainActor static func settings(_ entry:ModuleManifest.Entry,models:AppModels)->AnyView {AnyView(EmptyView())}
    @MainActor static func prepareStop(models:AppModels)throws->BuiltinModules.FinishStop? {
        guard let drain=try models.nativeFeatures.prepareStop(manifest.id) else{return nil}
        return {await drain.finish()}
    }
    @MainActor static func appearance(_ page:MainPage)->(glow:Bool,tint:Color?){(false,nil)}
    @MainActor static func prepareReview(_ args:[String],page:inout MainPage,models:AppModels) {}
    @MainActor static func snapshotReady(_ args:[String],models:AppModels,started:Date)->Bool {
        models.nativeFeatures.status(manifest.id).snapshotReady
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
