import AgentDoctor
import ModuleKit
import SwiftUI

enum AgentDiagnosticsModule:BuiltinModule {
    static let manifest=BuiltinModuleManifests.agents
    static let legacyMenuEntries:[String:String]=[:]
    static let sidebarSections:Set<BuiltinSidebarSection>=[.agents]
    @MainActor static var enabled:Bool {ModuleCenter.shared.isOn(manifest.id)}
    static func owns(_ page:MainPage)->Bool {
        if case .agents=page{return true}
        if case let .module(id,_)=page{return id==manifest.id}
        return false
    }
    static func canonicalArgument(_ argument:String)->String {argument}
    static func target(_ scene:String)->MainPage? {
        if scene=="agents"{return .agents(.home)}
        guard scene.hasPrefix("agents:"),let area=Area(rawValue:String(scene.dropFirst(7))) else{return nil}
        return .agents(.area(area))
    }
    static func supports(_ entry:ModuleManifest.Entry)->Bool {entry.kind == .page && entry.scene.flatMap(target) != nil}
    @MainActor static func sidebar(section:BuiltinSidebarSection,page:Binding<MainPage>,models:AppModels,row:@escaping @MainActor (BuiltinSidebarItem)->AnyView)->AnyView {
        guard section == .agents else{return AnyView(EmptyView())}
        return AnyView(AgentSidebar(scanner:models.agents,selection:page,row:row))
    }
    @MainActor static func page(_ entry:ModuleManifest.Entry,selection:Binding<MainPage>,models:AppModels)->AnyView {AnyView(AgentPage(scanner:models.agents,selection:selection,entry:entry))}
    @MainActor static func overlay(models:AppModels)->AnyView {
        guard let scanner=models.existingAgents else{return AnyView(EmptyView())}
        return AnyView(AgentResultsOverlay(scanner:scanner))
    }
    @MainActor static func settings(_ entry:ModuleManifest.Entry,models:AppModels)->AnyView {AnyView(EmptyView())}
    @MainActor static func prepareStop(models:AppModels)throws->BuiltinModules.FinishStop? {try models.prepareAgentsStop()}
    @MainActor static func appearance(_ page:MainPage)->(glow:Bool,tint:Color?) {
        let home=page == .agents(.home) || page == .module(manifest.id,"home") || page == .module(manifest.id,"")
        guard let report=AppModels.shared.agentReport else{return(home,Color(red:0.42,green:0.36,blue:1))}
        return(home,report.count(.error)>0 ? .red:report.count(.warning)>0 ? .orange:.green)
    }
    @MainActor static func prepareReview(_ args:[String],page:inout MainPage,models:AppModels) {
        guard let index=args.firstIndex(of:"--agents") else{return}
        let area=index+1<args.count ? Area(rawValue:args[index+1]):nil
        page = .agents(area.map{.area($0)} ?? .home)
        if enabled {models.agents.scan()}
    }
    @MainActor static func snapshotReady(_ args:[String],models:AppModels,started:Date)->Bool {models.agents.report != nil && !models.agents.scanning}
}
private struct AgentSidebar:View {
    @ObservedObject var scanner:AgentScanner
    @Binding var selection:MainPage
    let row:@MainActor (BuiltinSidebarItem)->AnyView
    var body:some View {
        ForEach(AgentDiagnosticsModule.manifest.entries.filter{$0.parent==nil || AgentDiagnosticsModule.owns(selection)},id:\.id) {entry in
            if let page=entry.scene.flatMap(AgentDiagnosticsModule.target) {
                let badge:Int = {if case let .agents(.area(area))=page{return scanner.report?.problemCount(in:area) ?? 0};return scanner.report?.problemCount ?? 0}()
                row(.init(entry:entry,target:page,tint:.purple,badge:badge,selected:selection==page || BuiltinModules.page(selection)?.target==page))
            }
        }
    }
}
private struct AgentPage:View {
    @ObservedObject var scanner:AgentScanner
    @Binding var selection:MainPage
    let entry:ModuleManifest.Entry
    private var page:MainPage {if case .agents=selection{return selection};return entry.scene.flatMap(AgentDiagnosticsModule.target) ?? .agents(.home)}
    var body:some View {
        Group {
            if case let .agents(.area(area))=page {AreaPage(scanner:scanner,area:area).id(area)}
            else {DiagnosticsHome(scanner:scanner,open:{selection = .agents(.area($0))})}
        }
        .onAppear{scanner.scan(ifOlderThan:60)}
        .onChange(of:page){_ in scanner.scan(ifOlderThan:60)}
    }
}

private struct AgentResultsOverlay:View {
    @ObservedObject var scanner:AgentScanner
    var body:some View {
        Color.clear.frame(width:0,height:0)
            .sheet(isPresented:Binding(get:{scanner.batch?.finished == true},set:{if !$0{scanner.batch=nil}})){BatchResult(scanner:scanner)}
    }
}
