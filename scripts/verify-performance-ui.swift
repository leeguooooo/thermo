@testable import PerformanceFeature
import AgentCore
import AppKit
import Darwin
import Foundation
import ModuleKit
import NativeFeatureAPI
import SwiftUI
import SystemServicesAPI
import ThermoKernel
import ThermoL10n
import ThermoUI

@MainActor final class PerformanceReviewState:ObservableObject {
    @Published var route=NativeFeatureRoute(BuiltinModuleManifests.performance.id,"overview")
    @Published var visible=false
    @Published var enabled=true
    @Published var problem:String?
    weak var store:NativeFeatureStore?
    var showWindow:()->Void = {}
    func present(_ request:NativePresentationRequest)->Bool {
        guard let store,NSApp.modalWindow==nil,
              let checked=try? store.catalog.normalizePresentation(request),store.canPresent(checked.route),
              store.preparePresentation(checked) else{return false}
        route=checked.route;store.setWindowPresentation(visible:visible,selection:route);showWindow();return true
    }
}
private struct PerformanceReviewWindow:View {
    @ObservedObject var state:PerformanceReviewState
    let store:NativeFeatureStore
    let toggle:()->Void
    var body:some View {
        HStack(spacing:0){
            VStack(alignment:.leading,spacing:8){
                Text("Thermo Performance QA").font(Theme.heading).padding(.bottom,12)
                ForEach(BuiltinModuleManifests.performance.entries,id:\.id){entry in
                    Button(tr(entry.title)){_=state.present(.init(route:.init(BuiltinModuleManifests.performance.id,entry.id)))}
                        .buttonStyle(.plain).foregroundStyle(state.route.entry==entry.id ? Theme.accent:Theme.textPrimary)
                        .padding(.vertical,6).accessibilityIdentifier("performance-qa-"+entry.id)
                }
                Spacer()
                if let problem=state.problem{Text(problem).font(Theme.caption).foregroundStyle(Theme.caution)}
                Button(state.enabled ? "Switch performance off":"Switch performance on",action:toggle)
                    .accessibilityIdentifier("performance-qa-toggle")
            }.padding(20).frame(width:228)
            Divider()
            if let content=store.page(state.route){content.environment(\.windowSamplingActive,state.visible)}
            else{Text(tr("This feature is switched off.")).frame(maxWidth:.infinity,maxHeight:.infinity)}
        }
        .background(Theme.canvas).preferredColorScheme(.dark)
    }
}
private struct PerformanceReviewPanel:View {
    @ObservedObject var state:PerformanceReviewState
    let store:NativeFeatureStore
    var body:some View {
        ScrollView(.vertical){
            if let content=store.compactPanel(.init(BuiltinModuleManifests.performance.id,"overview")){content}
            else{Text(tr("This feature is switched off."))}
        }.frame(minHeight:120,idealHeight:640,maxHeight:640).padding(Theme.Space.m).frame(width:372).background(Theme.canvas).preferredColorScheme(.dark)
    }
}
@MainActor final class PerformanceReview:NSObject,NSApplicationDelegate,NSPopoverDelegate {
    let root:URL,defaults:UserDefaults,state:PerformanceReviewState
    let telemetry:CoreTelemetry
    let helper:CoreHelperAdministration
    let store:NativeFeatureStore
    let popover=NSPopover()
    var window:NSWindow?,status:NSStatusItem?,timer:Timer?
    var observers:[NSObjectProtocol]=[]
    let started=Date()
    init(root:URL,defaults:UserDefaults){
        self.root=root;self.defaults=defaults
        let state=PerformanceReviewState();self.state=state
        let telemetry=CoreTelemetry(defaults:defaults,samplingAllowed:{true});self.telemetry=telemetry
        let helper=CoreHelperAdministration(automaticInteractionAllowed:false,beginMaintenance:{UUID()},endMaintenance:{_ in},
            fans:{telemetry.latest.sampledFans ?? []},refreshTelemetry:{telemetry.refreshCurrent()});self.helper=helper
        let definition=PerformanceFeature.definition{available in
            PerformanceSession(availability:available,telemetry:telemetry,administration:helper,fanFactory:helper,defaults:defaults,showSettings:{},
                makeRecorder:{PulseRecorder(readHistory:{[]},samplingAllowed:{false},readOnBattery:{false})},actionsAllowed:{false})
        }
        store=NativeFeatureStore(definitions:[definition],enabled:{_ in ModulePreferences.isEnabled(BuiltinModuleManifests.performance,in:defaults)},navigation:.init(show:{state.present($0)}))
        super.init();state.store=store;state.showWindow={[weak self] in self?.popover.performClose(nil);self?.window?.makeKeyAndOrderFront(nil)}
    }
    func applicationDidFinishLaunching(_ notification:Notification){
        let menu=NSMenu(),top=NSMenuItem(),commands=NSMenu()
        for (title,action,key) in [("Show console",#selector(showConsole),"o"),("Show menu panel",#selector(showPanel),"p"),("Quit performance QA",#selector(NSApplication.terminate(_:)),"q")]{
            let item=commands.addItem(withTitle:title,action:action,keyEquivalent:key);item.target=action == #selector(NSApplication.terminate(_:)) ? NSApp:self
        }
        top.submenu=commands;menu.addItem(top);NSApp.mainMenu=menu
        let window=NSWindow(contentRect:.init(x:160,y:100,width:1100,height:740),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.title="Thermo Performance QA";self.window=window
        window.contentViewController=NSHostingController(rootView:PerformanceReviewWindow(state:state,store:store,toggle:{[weak self] in self?.toggle()}))
        popover.behavior = .transient;popover.animates=false;popover.delegate=self
        let panelHost=NSHostingController(rootView:PerformanceReviewPanel(state:state,store:store));panelHost.sizingOptions=[]
        popover.contentViewController=panelHost
        status=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        status?.button?.title="PQ";status?.button?.setAccessibilityLabel("Thermo Performance QA")
        status?.button?.target=self;status?.button?.action=#selector(showPanel)
        for name in [NSWindow.didChangeOcclusionStateNotification,NSWindow.didMiniaturizeNotification,NSWindow.didDeminiaturizeNotification,NSWindow.willCloseNotification]{
            observers.append(NotificationCenter.default.addObserver(forName:name,object:window,queue:.main){[weak self] event in MainActor.assumeIsolated{
                guard let self else{return}
                if event.name==NSWindow.willCloseNotification{self.state.visible=false;self.store.setWindowPresentation(visible:false,selection:self.state.route);self.store.retireVisibility()}
                else{self.visibilityChanged()}
            }})
        }
        store.start(BuiltinModuleManifests.performance.id);showConsole()
        timer=Timer.scheduledTimer(withTimeInterval:1,repeats:true){[weak self] _ in MainActor.assumeIsolated{self?.record()}}
        print("PERFORMANCE_QA private feature; system actions/helper interaction/history recording disabled");fflush(stdout)
    }
    @objc func showConsole(){window?.makeKeyAndOrderFront(nil);visibilityChanged()}
    private func visibilityChanged(){
        state.visible=window.map{$0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)} ?? false
        store.setWindowPresentation(visible:state.visible,selection:state.route)
    }
    @objc func showPanel(){
        if popover.isShown{popover.performClose(nil);return}
        guard let button=status?.button else{return}
        store.setMenuPanelVisible(true)
        if let host=popover.contentViewController as? NSHostingController<PerformanceReviewPanel>{
            let size=host.sizeThatFits(in:NSSize(width:372,height:CGFloat.greatestFiniteMagnitude))
            popover.contentSize = .init(width:size.width,height:min(size.height,((button.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? (size.height+24))-24))
        }
        popover.show(relativeTo:button.bounds,of:button,preferredEdge:.minY)
    }
    func popoverDidClose(_ notification:Notification){store.setMenuPanelVisible(false)}
    func toggle(){
        let id=BuiltinModuleManifests.performance.id
        if state.enabled{
            do{
                let drain=try store.prepareStop(id)
                Task{@MainActor in
                    await drain?.finish();defaults.set(false,forKey:"module.enabled."+id);state.enabled=false;state.problem=nil;record()
                }
            }catch{state.problem=error.localizedDescription}
        }else{
            defaults.set(true,forKey:"module.enabled."+id);state.enabled=true;state.problem=nil
            store.start(id);store.setWindowPresentation(visible:state.visible,selection:state.route);record()
        }
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool{showConsole();return false}
    func applicationWillTerminate(_ notification:Notification){
        timer?.invalidate();for observer in observers{NotificationCenter.default.removeObserver(observer)}
        store.shutdown();record();print("PERFORMANCE_QA_EXIT");fflush(stdout)
    }
    func record(){
        var usage=rusage();guard getrusage(RUSAGE_SELF,&usage)==0 else{return}
        let memory=ProcessTable.memory(getpid()),status=store.status(BuiltinModuleManifests.performance.id),r=status.readers
        let cpu=Double(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)+Double(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1e6
        let values:[String:Any]=["at":Date().timeIntervalSince1970,"pid":getpid(),"elapsed":Date().timeIntervalSince(started),
            "cpuSeconds":cpu,"footprintKB":memory.footprintKB ?? -1,"rssKB":memory.residentKB ?? -1,
            "page":state.route.entry,"windowVisible":state.visible,"panelOpen":store.hostPresentation.menuPanelVisible,"enabled":state.enabled,
            "cpuSampling":r["cpu"]?.sampling ?? false,"gpuSampling":r["gpu"]?.sampling ?? false,"memorySampling":r["memory"]?.sampling ?? false,
            "panelSampling":r["panel"]?.sampling ?? false,"pulseSampling":r["pulse"]?.sampling ?? false,"pulseHolders":r["pulse"]?.holders ?? 0,
            "historyPoints":telemetry.latest.history.count,"systemActions":false,"helperInteraction":false,"historyRecording":false]
        guard var data=try? JSONSerialization.data(withJSONObject:values,options:.sortedKeys) else{return};data.append(10)
        let file=root.appendingPathComponent("samples.jsonl")
        if let handle=try? FileHandle(forWritingTo:file){defer{try? handle.close()};_=try? handle.seekToEnd();try? handle.write(contentsOf:data)}else{try? data.write(to:file)}
    }
}
@main struct PerformanceReviewMain {
    @MainActor static func main(){
        guard Bundle.main.bundleIdentifier?.hasPrefix("dev.thermo.performance-review.")==true,
              let path=Bundle.main.object(forInfoDictionaryKey:"ThermoPerformanceFixture") as?String else{exit(2)}
        let root=URL(fileURLWithPath:path)
        guard root.lastPathComponent.hasPrefix("thermo-performance-review-"),FileManager.default.fileExists(atPath:root.appendingPathComponent(".thermo-performance-fixture").path) else{exit(3)}
        _=freopen(root.appendingPathComponent("trace.log").path,"a",stdout)
        let defaults=UserDefaults.standard
        L10n.apply(preference:defaults.string(forKey:L10n.defaultsKey) ?? "system")
        let app=NSApplication.shared;app.setActivationPolicy(.regular)
        let delegate=PerformanceReview(root:root,defaults:defaults);app.delegate=delegate
        DispatchQueue.main.asyncAfter(deadline:.now()+1800){app.terminate(nil)}
        withExtendedLifetime(delegate){app.run()}
    }
}
