import Combine
import CleanKit
import Foundation
import ModuleKit
import NativeFeatureAPI
import SwiftUI
import SystemServicesAPI
import ThermoKit
import ThermoL10n
import ThermoUI

@MainActor final class PerformanceSession: ObservableObject, NativeFeatureSession {
    private let availability: FeatureAvailability
    private let telemetry: any TelemetryReadService
    private let administration: any HelperAdministration
    private let fanFactory: any FanPolicyAccessFactory
    private let defaults: UserDefaults
    private let showSettings: @MainActor @Sendable () -> Void
    private let lifetime = FeatureSamplingLifetime()
    private let workerAllowed: @Sendable () -> Bool
    private let makeRecorder: (@MainActor () -> PulseRecorder)?
    @Published private(set) var retiring = false
    @Published private var issue: String?
    private var host = NativeHostPresentation()
    private var started = false
    private var operations = Set<UUID>()
    private var inspections: [UUID:ProcessExplanationModel] = [:]
    private var storedModel: PerformanceModel?
    private var storedCPU: ComputeModel?, storedGPU: ComputeModel?
    private var storedMemory: MemoryModel?, storedPanel: PanelModel?
    private var storedPulse: SystemPulse?, storedRecorder: PulseRecorder?
    private var storedEvents: TimelineEvents?, storedAdvice: MemoryReliefAdvice?
    var acceptsWork: Bool { !retiring && availability.acceptsWork && workerAllowed() }

    init(availability: FeatureAvailability, telemetry: any TelemetryReadService,
         administration: any HelperAdministration, fanFactory: any FanPolicyAccessFactory,
         defaults: UserDefaults, showSettings: @escaping @MainActor @Sendable () -> Void,
         makeRecorder: (@MainActor () -> PulseRecorder)? = nil) {
        self.availability=availability; self.telemetry=telemetry; self.administration=administration
        self.fanFactory=fanFactory; self.defaults=defaults; self.showSettings=showSettings; self.makeRecorder=makeRecorder
        let gate=lifetime; _ = gate.start()
        workerAllowed={gate.current() != nil && ModulePreferences.isEnabled(BuiltinModuleManifests.performance,in:defaults)}
    }
    private func visible(_ entry: String) -> Bool {
        acceptsWork && host.windowVisible && host.selection == .init(BuiltinModuleManifests.performance.id,entry)
    }
    private var pulseVisible: Bool { acceptsWork && (host.menuPanelVisible || visible("overview") || visible("memory")) }
    private var model: PerformanceModel {
        if let storedModel { return storedModel }
        let value=PerformanceModel(telemetry:telemetry,administration:administration,fanFactory:fanFactory,defaults:defaults,available:{[weak self] in self?.acceptsWork == true})
        storedModel=value; value.setHostPresentation(host); return value
    }
    private func compute(_ gpu: Bool) -> ComputeModel {
        if let value=gpu ? storedGPU:storedCPU { return value }
        let value=ComputeModel(includeGPU:gpu,samplingAllowed:{[weak self] in self?.visible(gpu ? "gpu":"cpu") == true})
        if gpu { storedGPU=value } else { storedCPU=value }; return value
    }
    private var recorder: PulseRecorder {
        if let storedRecorder { return storedRecorder }
        let value=makeRecorder?() ?? PulseRecorder(samplingAllowed:workerAllowed)
        storedRecorder=value; return value
    }
    private var events: TimelineEvents {
        if let storedEvents { return storedEvents }
        let value=TimelineEvents(available:{[weak self] in self?.acceptsWork == true}); storedEvents=value; return value
    }
    private var pulse: SystemPulse {
        if let storedPulse { return storedPulse }
        let value=SystemPulse(samplingAllowed:{[weak self] in self?.pulseVisible == true},observe:{[weak self] in self?.events.observe($0)})
        storedPulse=value; return value
    }
    private var memory: MemoryModel {
        if let storedMemory { return storedMemory }
        let history=recorder.history, programs=recorder.programHistory
        let value=MemoryModel(readHistory:{$0.isCancelled ? []:programs.records(since:Date().addingTimeInterval(-PulseHistory.keep))},
                              readDay:{history.records(since:Date().addingTimeInterval(-PulseHistory.keep))},
                              samplingAllowed:{[weak self] in self?.visible("memory") == true})
        storedMemory=value; return value
    }
    private var panel: PanelModel {
        if let storedPanel { return storedPanel }
        let pulse=self.pulse
        let value=PanelModel(holdPulse:{pulse.hold()},releasePulse:{pulse.release()},samplingAllowed:{[weak self] in self.map{$0.acceptsWork && $0.host.menuPanelVisible} == true})
        storedPanel=value; return value
    }
    private var advice: MemoryReliefAdvice {
        if let storedAdvice { return storedAdvice }
        let value=MemoryReliefAdvice(available:{[weak self] in self?.acceptsWork == true}); storedAdvice=value; return value
    }
    func beginOperation() -> UUID? {
        guard acceptsWork else{return nil};let id=UUID();operations.insert(id);return id
    }
    func endOperation(_ id:UUID){operations.remove(id)}
    private var operationAccess: PerformanceOperations {
        .init(begin:{[weak self] in
            self?.beginOperation()
        },end:{[weak self] in self?.endOperation($0)})
    }
    private func navigation(_ native: NativeNavigation) -> PerformanceNavigation {
        .init(native:native,available:{[weak self] in self?.acceptsWork == true},showSettings:showSettings)
    }
    private var inspectionFactory: PerformanceInspectionFactory {
        .init(make:{[weak self] in
            guard let self,self.acceptsWork else{return ProcessExplanationModel(available:{false})}
            let id=UUID()
            let value=ProcessExplanationModel(available:{[weak self] in self?.acceptsWork == true},workerAllowed:self.workerAllowed,released:{[weak self] in self?.inspections[id]=nil})
            self.inspections[id]=value;return value
        })
    }
    private func wrap<V: View>(_ content: V, navigation: NativeNavigation) -> AnyView {
        AnyView(PerformanceMountedView(session:self,content:AnyView(content))
            .defaultAppStorage(defaults)
            .environment(\.performanceOperations,operationAccess)
            .environment(\.performanceNavigation,self.navigation(navigation))
            .environment(\.performanceInspections,inspectionFactory))
    }
    @discardableResult private func ensureTelemetry() -> Bool {
        guard acceptsWork else{return false}
        do { try model.start(); if issue != nil {issue=nil}; return true } catch { issue=error.localizedDescription;return false }
    }
    func start() {
        guard acceptsWork,!started else{return}
        guard ensureTelemetry() else{return};started=true;recorder.start()
    }
    func hostPresentationChanged(_ value: NativeHostPresentation) {
        guard acceptsWork else{return}
        host=value;storedModel?.setHostPresentation(value)
        storedCPU?.reconcileVisibility();storedGPU?.reconcileVisibility();storedMemory?.reconcileVisibility()
        storedPanel?.setActive(value.menuPanelVisible)
        if let pulse=storedPulse {
            if pulseVisible && pulse.holderCount > 0 {pulse.start()} else if !pulseVisible {pulse.stop()}
        }
    }
    func page(_ route: NativeFeatureRoute, navigation: NativeNavigation) -> AnyView? {
        guard acceptsWork,route.module==BuiltinModuleManifests.performance.id else{return nil}
        let open=self.navigation(navigation).open
        func mounted<V:View>(_ view:V)->AnyView {wrap(view.onAppear{[weak self] in _=self?.ensureTelemetry()},navigation:navigation)}
        switch route.entry {
        case "cpu","gpu":
            let gpu=route.entry=="gpu"
            return mounted(ComputePage(gpu:gpu,model:compute(gpu),available:{[weak self] in self?.visible(gpu ? "gpu":"cpu") == true}))
        case "sensors":return mounted(SensorsPage(monitor:model))
        case "fans":
            return mounted(WindowPage(title:tr("Fans"),subtitle:tr("Choose how fast each fan runs. Settings stay when Thermo quits or updates.")){FansView(monitor:self.model)})
        case "overview":
            return mounted(OverviewPage(monitor:model,open:open).environmentObject(pulse).environmentObject(recorder).environmentObject(events))
        case "memory":
            return mounted(MemoryPage(model:memory,open:open).environmentObject(pulse).environmentObject(recorder).environmentObject(advice))
        default:return nil
        }
    }
    func ui(_ surface: NativeUISurface, navigation: NativeNavigation) -> AnyView? {
        guard acceptsWork else{return nil}
        switch surface {
        case let .compactPanel(route):
            guard route == .init(BuiltinModuleManifests.performance.id,"overview") else{return nil}
            let panel=self.panel
            return wrap(PerformanceCompactView(monitor:model).environmentObject(panel).environmentObject(pulse).onAppear{[weak self] in
                guard let self,self.acceptsWork else{return};_=self.ensureTelemetry();panel.setActive(self.host.menuPanelVisible)
            },navigation:navigation)
        case let .sidebar(location,_,rows):return wrap(PerformanceSidebar(monitor:model,location:location,rows:rows),navigation:navigation)
        case let .backdrop(route):return wrap(PerformanceBackdrop(monitor:model,glow:route.entry=="overview"),navigation:navigation)
        default:return nil
        }
    }
    var status: NativeFeatureStatus {
        var readers: [String:NativeReaderStatus]=[:]
        if let x=storedCPU {readers["cpu"] = .init(sampling:x.samplingActive,workInFlight:x.sampleInFlight,publishedAt:x.current?.sampled)}
        if let x=storedGPU {readers["gpu"] = .init(sampling:x.samplingActive,workInFlight:x.sampleInFlight,publishedAt:x.current?.sampled)}
        if let x=storedMemory {readers["memory"] = .init(sampling:x.samplingActive,workInFlight:x.sampleInFlight,publishedAt:x.sampled)}
        if let x=storedPanel {readers["panel"] = .init(sampling:x.samplingActive,workInFlight:x.sampleInFlight)}
        if let x=storedPulse {readers["pulse"] = .init(sampling:x.samplingActive,holders:x.holderCount,publishedAt:x.current?.sampled)}
        if let x=storedRecorder {readers["history"] = .init(sampling:x.samplingActive,publishedAt:x.recent.last?.t)}
        return .init(modelLoaded:storedModel != nil || !readers.isEmpty,sampling:readers.values.contains{$0.sampling} || storedModel?.samplingActive == true,
                     snapshotReady:storedModel?.snapshot != nil || storedCPU?.current != nil || storedGPU?.current != nil || storedMemory?.sampled != nil,readers:readers)
    }
    func preparePresentation(_ route:NativeFeatureRoute,options:[String:NativeContextValue]) {
        guard acceptsWork else{return}
        if route.entry=="memory",case let .text(name)?=options["inspect"] {memory.inspect=name}
        if route.entry=="overview",case let .text(name)?=options["program"] {recorder.highlighted=name.isEmpty ? nil:name}
    }
    func prepareReview(_ route:NativeFeatureRoute,arguments:[String]) {
        guard acceptsWork else{return}
        if route.entry=="overview",arguments.contains("--render-preview") {_=ensureTelemetry();panel.setActive(host.menuPanelVisible)}
        if route.entry=="memory",let i=arguments.firstIndex(of:"--fixture"),i+1<arguments.count {advice.loadFixture(answer:arguments[i+1])}
    }
    func snapshotReady(_ route:NativeFeatureRoute,arguments:[String],started:Date)->Bool {
        guard acceptsWork else{return true}
        switch route.entry {
        case "cpu":return storedCPU?.current?.cpu != nil && Date().timeIntervalSince(started)>4
        case "gpu":return storedGPU?.current?.cpu != nil && Date().timeIntervalSince(started)>4
        case "memory":return storedMemory?.breakdown != nil && Date().timeIntervalSince(started)>4
        case "overview":return storedModel?.snapshot != nil && storedPulse?.sampled == true && storedRecorder?.diagnosis != nil && Date().timeIntervalSince(started)>4
        default:return storedModel?.snapshot != nil
        }
    }
    func didWake(){guard acceptsWork else{return};storedPanel?.resetBaselines();storedModel?.sampleNow()}
    func retireVisibility() {
        hostPresentationChanged(.init(windowVisible:false,menuPanelVisible:host.menuPanelVisible,selection:host.selection))
        storedCPU?.stop();storedGPU?.stop();storedMemory?.stop()
    }
    func quitBlocker()->NativeFeatureBlocker? {nil} // Preserve app exit's existing best-effort process-action contract.
    private var canStop: Bool {
        administration.latest.canRetirePerformance && operations.isEmpty && storedPulse.map{$0.quitting.isEmpty && $0.restarting==nil && !$0.actionReviewInFlight} != false && storedAdvice?.phase != .asking
    }
    func prepareStop() throws -> NativeFeatureDrain {
        guard canStop else{throw NativeFeatureBusy(tr("Wait for fan setup, memory relief or the current process action before switching this feature off."))}
        beginRetiring();return .init{[self] in await finishRetiring()}
    }
    private func beginRetiring() {
        guard !retiring else{return};retiring=true;lifetime.stop()
        storedModel?.beginStopping();storedRecorder?.beginStopping();storedPanel?.setActive(false);storedPulse?.stop()
        storedCPU?.stop();storedGPU?.stop();storedMemory?.stop()
        for model in Array(inspections.values){model.retire()}
    }
    private func finishRetiring() async {
        await storedModel?.finishStopping();await storedRecorder?.stop();await storedPulse?.finishStoppingFeature()
        await storedPanel?.finishStopping()
        for model in Array(inspections.values){await model.finishStopping()}
        while storedCPU?.sampleInFlight == true || storedGPU?.sampleInFlight == true || storedMemory?.sampleInFlight == true || storedPanel?.sampleInFlight == true {
            await withCheckedContinuation{done in DispatchQueue.main.asyncAfter(deadline:.now()+0.02){done.resume()}}
        }
        storedCPU?.releaseReadingsIfIdle();storedGPU?.releaseReadingsIfIdle();storedMemory?.releaseReadingsIfIdle()
        storedRecorder?.highlighted=nil;storedEvents?.retire();storedAdvice?.retire()
    }
    func shutdown(){beginRetiring()}
}

private struct PerformanceMountedView: View {
    @ObservedObject var session:PerformanceSession
    let content:AnyView
    var body:some View{if session.acceptsWork{content}}
}
private struct PerformanceBackdrop:View {
    @ObservedObject var monitor:PerformanceModel
    let glow:Bool
    var body:some View{WindowBackdrop(glow:glow,tint:heatColor(monitor.snapshot?.maximumKnownTemperature).opacity(0.8))}
}
private struct PerformanceSidebar:View {
    @ObservedObject var monitor:PerformanceModel
    let location:NativeSidebarLocation
    let rows:NativeSidebarRenderer
    @AppStorage(Settings.fahrenheit) private var fahrenheit=false
    private func section(_ entry:String)->NativeSidebarLocation {
        switch entry{case "overview":return .overview;case "sensors","fans":return .machine;default:return .resources}
    }
    private func tint(_ entry:String)->Color {
        switch entry{case "overview":return .orange;case "sensors":return .red;case "fans":return .blue;case "cpu":return .cyan;case "gpu":return .purple;default:return .green}
    }
    private func trailing(_ entry:String)->String? {
        switch entry{
        case "overview":return monitor.snapshot.map{tempText($0.maximumKnownTemperature,fahrenheit:fahrenheit)}
        case "fans":return monitor.snapshot.flatMap{FanControlPresentation.speedSummary($0.fans,stopped:monitor.stoppedFans)}
        case "memory":return monitor.systemMemory.map{String(format:"%.0f%%",Double($0.usedBytes)/Double(max(1,$0.totalBytes))*100)}
        default:return nil
        }
    }
    var body:some View{
        ForEach(BuiltinModuleManifests.performance.entries.filter{section($0.id)==location},id:\.id){entry in
            rows(.init(route:.init(BuiltinModuleManifests.performance.id,entry.id),tint:tint(entry.id),trailing:trailing(entry.id),
                       trailingColor:entry.id=="overview" ? monitor.snapshot.map{heatColor($0.maximumKnownTemperature)}:nil))
        }
    }
}
