import CleanKit
import ModuleKit
import NativeFeatureAPI
import SwiftUI
import ThermoUI
import ThermoL10n

package enum BrowserFeature {
    package static var registration:NativeFeatureDefinition {
        .init(manifest:BuiltinModuleManifests.browser,pageContracts:[
            .init(entry:"home",fields:[.init("app",kind:.text,defaultValue:.text("Google Chrome"))],
                  optionFields:[.init("appMemoryKB",kind:.integer,required:false),.init("gpuMemoryKB",kind:.integer,required:false)],
                  checkOptions:{options in
                      for value in options.values {
                          guard case let .integer(kb)=value,kb>=0,UInt64(kb)<=UInt64(Int.max) else{throw NativeRouteError("Invalid browser memory size.")}
                      }
                  },check:{context in
                      guard case let .text(app)?=context["app"],!app.isEmpty,!app.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else{throw NativeRouteError("Invalid browser name.")}
                  })
        ],menuShortcuts:["archive":"s"],resolveLegacyPage:{argument in
            guard argument == "pages" || argument.hasPrefix("pages:") else{return nil}
            let app=argument.hasPrefix("pages:") ? String(argument.dropFirst(6)):""
            return route(app.isEmpty ? "Google Chrome":app)
        },makeSession:{BrowserSession(availability:$0)})
    }
    static func route(_ app:String)->NativeFeatureRoute {.init(BuiltinModuleManifests.browser.id,"home",context:["app":.text(app)])}
}

@MainActor final class BrowserSession:NativeFeatureSession {
    typealias DiagnosticsFactory = @MainActor (@escaping ()->Bool,String,Int?,Int?)->ChromePagesModel
    typealias WorkspaceFactory = @MainActor (@escaping ()->Bool,String)->TabWorkspaceModel
    let availability:FeatureAvailability
    let archive=BrowserArchiveState()
    private let makeDiagnostics:DiagnosticsFactory
    private let makeWorkspace:WorkspaceFactory
    private var checks:[String:ChromePagesModel]=[:]
    private var spaces:[String:TabWorkspaceModel]=[:]
    private var automation:TabAutomation?
    init(availability:FeatureAvailability,
         makeDiagnostics:@escaping DiagnosticsFactory={ChromePagesModel(enabled:$0,app:$1,appMemoryKB:$2,gpuKB:$3)},
         makeWorkspace:@escaping WorkspaceFactory={TabWorkspaceModel(enabled:$0,app:$1)}) {
        self.availability=availability;self.makeDiagnostics=makeDiagnostics;self.makeWorkspace=makeWorkspace
    }
    func diagnostics(_ app:String,memory:Int? = nil,gpu:Int? = nil)->ChromePagesModel {
        if let model=checks[app] {
            if let memory {model.appMemoryKB=memory};if let gpu {model.gpuKB=gpu}
            return model
        }
        let availability=availability
        let model=makeDiagnostics({availability.acceptsWork},app,memory,gpu)
        checks[app]=model;return model
    }
    func workspace(_ app:String)->TabWorkspaceModel {
        if let model=spaces[app]{return model}
        let availability=availability
        let model=makeWorkspace({availability.acceptsWork},app)
        spaces[app]=model;return model
    }
    private func app(_ route:NativeFeatureRoute)->String {
        if case let .text(app)?=route.context["app"] {return app}
        preconditionFailure("Browser route was not normalized")
    }
    func page(_ route:NativeFeatureRoute,navigation:NativeNavigation)->AnyView? {
        guard availability.acceptsWork else{return nil}
        return AnyView(BrowserRoot(session:self,app:app(route)))
    }
    func preparePresentation(_ route:NativeFeatureRoute,options:[String:NativeContextValue]) {
        guard availability.acceptsWork else{return}
        func kb(_ key:String)->Int? {if case let .integer(value)?=options[key]{return Int(exactly:value)};return nil}
        let memory=kb("appMemoryKB"),gpu=kb("gpuMemoryKB")
        guard memory != nil || gpu != nil else{return}
        _=diagnostics(app(route),memory:memory,gpu:gpu)
    }
    var status:NativeFeatureStatus {.init(modelLoaded:!checks.isEmpty || !spaces.isEmpty,sampling:checks.values.contains{$0.running})}
    func start() {
        guard availability.acceptsWork,automation==nil else{return}
        let availability=availability
        let model=TabAutomation(enabled:{availability.acceptsWork});automation=model;model.start()
    }
    func shutdown(){automation?.stop();retireVisibility()}
    func retireVisibility() {
        for model in checks.values where model.running {model.stop()}
        for model in spaces.values {model.retireRead()}
    }
    func quitBlocker()->NativeFeatureBlocker? {
        let app=checks.values.first{$0.closing != nil}?.app
            ?? spaces.values.first{$0.mutating || $0.work.hasOperations}?.app
            ?? (automation?.running == true ? "Google Chrome":nil)
        return app.map{.init(reason:tr("Wait for browser changes or tab grouping to finish before switching this feature off."),route:BrowserFeature.route($0))}
    }
    func prepareStop()throws->NativeFeatureDrain {
        if let blocker=quitBlocker(){throw NativeFeatureBusy(blocker.reason)}
        automation?.stop();archive.requested=false
        let checks=Array(checks.values),spaces=Array(spaces.values)
        for model in checks {model.stopFeature()};for model in spaces {model.stopFeature()}
        return .init { [self] in
            for model in checks {await model.finishFeatureStop()}
            for model in spaces {await model.finishFeatureStop()}
            self.checks=[:];self.spaces=[:];automation=nil
        }
    }
    func prepareReview(_ route:NativeFeatureRoute,arguments:[String]) {
        guard availability.acceptsWork,arguments.contains("--chrome-pages") else{return}
        let app=app(route),hog=MachinePulse.sample().hogs.first{$0.name==app}
        let model=diagnostics(app,memory:hog?.memoryKB,gpu:hog?.parts?.first{$0.role=="GPU"}?.memoryKB)
        if let index=arguments.firstIndex(of:"--fixture"),index+2<arguments.count {model.loadFixture(before:arguments[index+1],after:arguments[index+2])}
    }
    func snapshotReady(_ route:NativeFeatureRoute,arguments:[String],started:Date)->Bool {
        let app=app(route)
        let diagnostics=arguments.firstIndex(of:"--tabs-task").flatMap{$0+1<arguments.count ? arguments[$0+1]:nil} == "diagnostics"
        if diagnostics {return checks[app].map{$0.diagnosis != nil && !$0.running} ?? false}
        return spaces[app]?.didLoad == true
    }
    func activate(_ entry:NativeUIEntryRef,navigation:NativeNavigation)->Bool {
        guard availability.acceptsWork,entry.module==BuiltinModuleManifests.browser.id,
              BuiltinModuleManifests.browser.entries.contains(where:{$0.id==entry.entry && $0.kind == .menuBarItem && $0.scene=="archive-tabs"}) else{return false}
        archive.requested=true
        guard navigation.show(BrowserFeature.route("Google Chrome")) else{archive.requested=false;return false}
        NotificationCenter.default.post(name:BrowserArchiveState.notification,object:archive)
        return true
    }
}

struct BrowserHeader:View {
    @Binding var section:BrowserSection
    let subtitle:String
    var body:some View {
        PageHeader(title:tr("Tab organizer"),subtitle:subtitle) {EmptyView()} below: {
            ThermoTabs(selection:$section,options:TabWorkspaceTask.allCases.map{(BrowserSection.task($0),$0.title)} + [(.diagnostics,tr("Memory diagnostics"))],label:tr("Browser pages"))
        }.padding(.horizontal,Theme.pagePadding).padding(.top,Theme.pageTop).padding(.bottom,Theme.Space.l)
    }
}
private struct BrowserRoot:View {
    let session:BrowserSession
    let app:String
    @State private var section:BrowserSection = {
        let args=CommandLine.arguments
        if args.contains("--offscreen"),let i=args.firstIndex(of:"--tabs-task"),i+1<args.count {
            if args[i+1]=="diagnostics"{return .diagnostics}
            return .task(TabWorkspaceTask(rawValue:args[i+1]) ?? .organize)
        }
        return .task(.organize)
    }()
    var body:some View {
        Group {switch section {
        case .diagnostics:ChromePagesView(model:session.diagnostics(app),embedded:true,section:$section)
        case .task:
            VStack(spacing:0) {
                BrowserHeader(section:$section,subtitle:tr("Group tabs without closing them, or save links and close tabs you are not using."))
                TabWorkspaceView(model:session.workspace(app),archive:session.archive,task:Binding(get:{if case let .task(task)=section{return task};return .organize},set:{section = .task($0)}))
            }
        }}.onReceive(NotificationCenter.default.publisher(for:BrowserArchiveState.notification,object:session.archive)) {_ in
            if session.availability.acceptsWork,session.archive.requested,app=="Google Chrome" {section = .task(.archive)}
        }
    }
}
