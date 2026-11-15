import AgentDoctor
import ModuleKit
import NativeFeatureAPI
import SwiftUI
import ThermoUI
import ThermoL10n

package enum AgentDiagnosticsFeature {
    package static var registration:NativeFeatureDefinition {
        .init(manifest:BuiltinModuleManifests.agents,ui:.init(sidebarLocations:[.agents],hasOverlay:true,hasBackdrop:true),resolveLegacyPage:{argument in
            guard argument=="agents" || argument.hasPrefix("agents:") else{return nil}
            let suffix=argument.hasPrefix("agents:") ? String(argument.dropFirst(7)):""
            return route(Area(rawValue:suffix))
        },makeSession:{AgentDiagnosticsSession(availability:$0)})
    }
    static func route(_ area:Area?)->NativeFeatureRoute {.init(BuiltinModuleManifests.agents.id,area?.rawValue ?? "home")}
}
@MainActor final class AgentDiagnosticsSession:NativeFeatureSession {
    let scanner:AgentScanner
    private let availability:FeatureAvailability
    init(availability:FeatureAvailability,makeScanner:@MainActor (@escaping ()->Bool)->AgentScanner = {AgentScanner(enabled:$0)}) {
        self.availability=availability;self.scanner=makeScanner({availability.acceptsWork})
    }
    func page(_ route:NativeFeatureRoute,navigation:NativeNavigation)->AnyView? {
        guard availability.acceptsWork else{return nil}
        return AnyView(AgentPage(scanner:scanner,route:route,navigation:navigation))
    }
    func ui(_ surface:NativeUISurface,navigation:NativeNavigation)->AnyView? {
        guard availability.acceptsWork else{return nil}
        switch surface {
        case let .sidebar(location,selection,rows):
            guard location == .agents else{return nil}
            return AnyView(AgentSidebar(scanner:scanner,selection:selection,rows:rows))
        case .inlineSettings,.renderPreview:return nil
        case .windowOverlay:return AnyView(AgentResultsOverlay(scanner:scanner))
        case let .backdrop(route):return AnyView(AgentBackdrop(scanner:scanner,glow:BuiltinModuleManifests.agents.entries.first{$0.id==route.entry}?.parent == nil))
        }
    }
    var status:NativeFeatureStatus {.init(modelLoaded:true,sampling:scanner.scanning,snapshotReady:scanner.report != nil && !scanner.scanning)}
    func retireVisibility(){scanner.stopScan();scanner.toolUsage.stop();scanner.mcpBatch.cancel()}
    func quitBlocker()->NativeFeatureBlocker? {
        guard !scanner.canStopFeature else{return nil}
        return .init(reason:tr("Wait for the confirmed agent configuration changes before switching diagnostics off."),route:AgentDiagnosticsFeature.route(nil))
    }
    func prepareReview(_ route:NativeFeatureRoute,arguments:[String]) {if availability.acceptsWork,arguments.contains("--agents"){scanner.scan()}}
    func prepareStop()throws->NativeFeatureDrain {
        if let blocker=quitBlocker(){throw NativeFeatureBusy(blocker.reason)}
        scanner.stopFeature()
        return .init{[scanner] in await scanner.finishFeatureStop()}
    }
}
private struct AgentSidebar:View {
    @ObservedObject var scanner:AgentScanner
    let selection:NativeFeatureRoute?
    let rows:NativeSidebarRenderer
    var body:some View {
        ForEach(BuiltinModuleManifests.agents.entries.filter{$0.kind == .page && ($0.parent == nil || selection?.module==BuiltinModuleManifests.agents.id)},id:\.id) {entry in
            let area=Area(rawValue:entry.id)
            rows(.init(route:.init(BuiltinModuleManifests.agents.id,entry.id),tint:area.map(AgentStyle.tint) ?? .purple,badge:area.map{scanner.report?.problemCount(in:$0) ?? 0} ?? (scanner.report?.problemCount ?? 0)))
        }
    }
}
private struct AgentPage:View {
    @ObservedObject var scanner:AgentScanner
    let route:NativeFeatureRoute
    let navigation:NativeNavigation
    var body:some View {
        Group {
            if let area=Area(rawValue:route.entry) {AreaPage(scanner:scanner,area:area).id(area)}
            else {DiagnosticsHome(scanner:scanner,open:{_ = navigation.show(AgentDiagnosticsFeature.route($0))})}
        }
        .onAppear{scanner.scan(ifOlderThan:60)}
        .onChange(of:route){_ in scanner.scan(ifOlderThan:60)}
    }
}
private struct AgentBackdrop:View {
    @ObservedObject var scanner:AgentScanner
    let glow:Bool
    private var tint:Color {
        guard let report=scanner.report else{return Color(red:0.42,green:0.36,blue:1)}
        return report.count(.error)>0 ? .red:report.count(.warning)>0 ? .orange:.green
    }
    var body:some View {WindowBackdrop(glow:glow,tint:tint)}
}
private struct AgentResultsOverlay:View {
    @ObservedObject var scanner:AgentScanner
    var body:some View {
        Color.clear.frame(width:0,height:0)
            .sheet(isPresented:Binding(get:{scanner.batch?.finished == true},set:{if !$0{scanner.batch=nil}})){BatchResult(scanner:scanner)}
    }
}
