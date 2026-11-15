import Combine
import Foundation
import SystemServicesAPI
import ThermoKit
import ThermoL10n

/// Presentation bridge during the private Performance extraction; owns no sampler or helper IPC.
@MainActor final class Monitor:ObservableObject {
    private let telemetry:any TelemetryReadService
    let administration:any HelperAdministration
    private let fanFactory:any FanPolicyAccessFactory
    private let samplingAllowed:@Sendable ()->Bool
    private var sampling:(any TelemetrySamplingLease)?
    private var fan:(any FanPolicyAccess)?
    private var observations=Set<AnyCancellable>()
    private var surface:TelemetrySurface = .overview
    private var unnamed=false
    private var lastSnapshot:Date?
    private var lastHelperRefresh=Date.distantPast
    @Published var iconHidden=false
    @Published private var reviewError:String?
    #if DEBUG
    @Published private var reviewFrame:TelemetryReading?
    private var reviewStreak:[Int:Int]=[:]
    #endif
    private var frame:TelemetryReading {
        #if DEBUG
        if let reviewFrame{return reviewFrame}
        #endif
        return telemetry.latest
    }
    private var helper:HelperReading{administration.latest}
    var snapshot:Snapshot?{frame.snapshot}
    var latest:Snapshot?{frame.latestSnapshot}
    var sampledFans:[FanReading]?{frame.sampledFans}
    var fanReadingsUnavailable:Bool{frame.fanReadingsUnavailable}
    var stoppedFans:Set<Int>{frame.stoppedFans}
    var fanEmptyMessage:String{tr(fanReadingsUnavailable ? "Fan readings unavailable":"Checking…")}
    var history:[HistoryPoint]{frame.history}
    var model:String{frame.model}
    var systemMemory:SystemStats.Memory?{frame.memory}
    var systemDisk:SystemStats.Disk?{frame.disk}
    var menuLive:MenuLiveValues{telemetry.latest.menu}
    var helperState:HelperState{helper.phase}
    var policies:[Int:FanPolicy]{helper.policies}
    var policiesAvailable:Bool{helper.policiesAvailable}
    var fanControlState:FanControlState?{helper.fanControl}
    var applyingPolicies:Bool{helper.applyingPolicies}
    var installingHelper:Bool{helper.installing}
    var uninstallingHelper:Bool{helper.uninstalling}
    var helperBusy:Bool{helper.busy}
    var pendingPolicies:[Int:FanPolicy]{helper.pendingPolicies}
    var lidAwake:LidAwakeState?{helper.lidAwake}
    var lidAwakePending:Bool{helper.lidAwakePending}
    var lidAwakeBusy:Bool{helper.lidAwakeBusy}
    var settingUp:Bool{helper.settingUp}
    var setupStarted:Date?{helper.setupStarted}
    var usesSMAppService:Bool{helper.usesSMAppService}
    var lastError:String? {
        get{reviewError ?? helper.error ?? frame.error}
        set{reviewError=newValue;if newValue==nil{administration.dismissError();telemetry.dismissError()}}
    }
    var popoverOpen=false{didSet{if popoverOpen != oldValue{visibilityChanged()}}}
    var windowOpen=false{didSet{if windowOpen != oldValue{visibilityChanged()}}}
    var watched:Bool{popoverOpen || windowOpen}
    var panelVisible:Bool{watched}
    var samplingActive:Bool{telemetry.latest.sampling}
    var canStopFeature:Bool{helper.canRetirePerformance}
    var interval:TimeInterval{Settings.intervalValue(UserDefaults.standard.double(forKey:Settings.interval))}
    var onUpdate:((Snapshot)->Void)?
    var onMenuUpdate:(()->Void)?
    init(telemetry:any TelemetryReadService,administration:any HelperAdministration,fanFactory:any FanPolicyAccessFactory,
         startMonitoring:Bool = true,samplingAllowed:@escaping @Sendable ()->Bool){
        self.telemetry=telemetry;self.administration=administration;self.fanFactory=fanFactory;self.samplingAllowed=samplingAllowed
        telemetry.readings.sink{[weak self] _ in self?.objectWillChange.send()}.store(in:&observations)
        administration.readings.sink{[weak self] _ in self?.objectWillChange.send()}.store(in:&observations)
        telemetry.menuReadings.sink{[weak self] value in
            guard let self else{return}
            if let snapshot=value.snapshot,self.lastSnapshot != snapshot.timestamp{
                self.lastSnapshot=snapshot.timestamp;self.onUpdate?(snapshot)
                if self.watched,Date().timeIntervalSince(self.lastHelperRefresh)>=10{self.refreshFanObservation()}
            }
            self.onMenuUpdate?()
        }.store(in:&observations)
        if startMonitoring && samplingAllowed(){startFeature();refreshFanObservation()}
    }
    func startFeature(){
        guard samplingAllowed(),sampling==nil else{return}
        do{sampling=try telemetry.beginPerformanceSampling(available:{[samplingAllowed] in samplingAllowed()})}
        catch{reviewError=error.localizedDescription;return}
        fan=fanFactory.bind(available:{[samplingAllowed] in samplingAllowed()});updateDemand()
    }
    private func updateDemand(){sampling?.setDemand(.init(visible:watched,surface:popoverOpen ? .overview:surface,includeUnnamed:unnamed))}
    private func visibilityChanged(){objectWillChange.send();updateDemand();if watched{sampleNow();refreshFanObservation()}}
    func setWindowSurface(_ surface:TelemetrySurface){guard self.surface != surface else{return};self.surface=surface;updateDemand();if watched{sampleNow()}}
    func showUnnamedSensors(_ value:Bool){unnamed=value;updateDemand();sampleNow()}
    func sampleNow(){if let sampling{sampling.refresh()}else{telemetry.refreshCurrent()}}
    func reschedule(){telemetry.preferencesDidChange()}
    func resetMenuBaselines(){telemetry.resetMenuBaselines()}
    func beginStoppingFeature(){
        sampling?.beginStopping();fan?.beginRetiring()
        #if DEBUG
        reviewFrame=nil;reviewStreak=[:]
        #endif
    }
    func finishStoppingFeature() async{await sampling?.finishStopping();await fan?.finishRetiring();sampling=nil;fan=nil;onMenuUpdate?()}
    func refreshFanObservation(){lastHelperRefresh=Date();fan?.refreshObservation()}
    func refreshHelper(){lastHelperRefresh=Date();administration.refresh()}
    func beginSetup(){administration.install()}
    func stopSetup(){administration.stopSetup()}
    func installHelper(){administration.install()}
    func installHelperWithPassword(){administration.installWithPassword()}
    func uninstallHelper(finished:@escaping ()->Void = {}){administration.uninstall(finished:finished)}
    func openLoginItemsSettings(){administration.openLoginItemsSettings()}
    func setLidAwake(_ on:Bool){administration.setLidAwake(on)}
    func setPolicy(_ policy:FanPolicy,fan:Int){setPolicy(policy,fans:[fan])}
    func setPolicy(_ policy:FanPolicy,fans:[Int]){
        guard samplingAllowed() else{return}
        if fan==nil{fan=fanFactory.bind(available:{[samplingAllowed] in samplingAllowed()})}
        fan?.request(policy,fans:fans)
    }
    nonisolated static func suppressesAutomaticControl(arguments:[String])->Bool{arguments.contains{["--offscreen","--snapshot","--render-preview","--verify-lifecycle","--ui-review"].contains($0)}}
    #if DEBUG
    // Display-only fixture input, never used to grant helper or sampling authority.
    func publishSnapshot(_ snapshot:Snapshot,parts:SamplerParts){
        var value=reviewFrame ?? telemetry.latest
        value.fanReadingsUnavailable=parts.contains(.fans) && snapshot.fansAvailable == false
        let fans=parts.contains(.fans) && snapshot.hasFanReadings ? snapshot.fans:nil
        if let fans{reviewStreak=Self.zeroStreaks(reviewStreak,fans:fans);value.stoppedFans=Set(reviewStreak.filter{$0.value>=Self.stoppedAfterSamples}.keys)}
        value.snapshot=snapshot;value.sampledFans=fans;reviewFrame=value
    }
    #endif
    nonisolated static let stoppedAfterSamples=3
    nonisolated static func zeroStreaks(_ previous:[Int:Int],fans:[FanReading])->[Int:Int]{
        var next:[Int:Int]=[:];for fan in fans where fan.rpm==0{next[fan.id]=(previous[fan.id] ?? 0)+1};return next
    }
}
