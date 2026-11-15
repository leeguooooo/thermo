import Combine
import Foundation
import NativeFeatureAPI
import SystemServicesAPI
import ThermoKit
import ThermoL10n
import UserNotifications

/// App-owned reading authority. Only a current performance lease can activate its worker.
@MainActor package final class CoreTelemetry:TelemetryReadService {
    typealias WorkerFactory = @MainActor (FeatureSamplingLifetime)->TelemetryWorker
    private let defaults:UserDefaults
    private let allowed:@Sendable ()->Bool
    private let makeWorker:WorkerFactory
    private let lifetime=FeatureSamplingLifetime()
    private var storedWorker:TelemetryWorker?
    private var lease:Lease?
    private var buffer:[HistoryPoint]=[]
    private var fanZeroStreak:[Int:Int]=[:]
    private var lastFanSample:Date?
    private var latestParts:SamplerParts=[]
    private var lastAlert=Date.distantPast
    private let values=PassthroughSubject<TelemetryReading,Never>()
    private let menu=CurrentValueSubject<MenuTelemetryReading,Never>(.init(snapshot:nil,values:.init(),sampling:false))
    package private(set) var latest=TelemetryReading()
    package var readings:AnyPublisher<TelemetryReading,Never>{values.eraseToAnyPublisher()}
    package var menuReadings:AnyPublisher<MenuTelemetryReading,Never>{menu.eraseToAnyPublisher()}
    package convenience init(defaults:UserDefaults = .standard,samplingAllowed:@escaping @Sendable ()->Bool) {
        self.init(defaults:defaults,samplingAllowed:samplingAllowed,makeWorker:{TelemetryWorker(lifetime:$0,allowed:samplingAllowed,defaults:defaults)})
    }
    init(defaults:UserDefaults,samplingAllowed:@escaping @Sendable ()->Bool,makeWorker:@escaping WorkerFactory){self.defaults=defaults;self.allowed=samplingAllowed;self.makeWorker=makeWorker}
    package func beginPerformanceSampling(available:@escaping @MainActor ()->Bool)throws->any TelemetrySamplingLease {
        guard available(),allowed() else{throw NativeFeatureBusy(tr("This feature is switched off."))}
        guard lease==nil else{throw NativeFeatureBusy("Performance sampling is still owned by the previous session.")}
        let value=Lease(owner:self,token:lifetime.start(),available:available)
        lease=value;latest.sampling=true
        configure(value)
        return value
    }
    private var worker:TelemetryWorker {
        if let storedWorker{return storedWorker}
        let made=makeWorker(lifetime);storedWorker=made;return made
    }
    private func owns(_ lease:Lease)->Bool{self.lease === lease}
    private func accepts(_ lease:Lease)->Bool{owns(lease) && !lease.stopping && lease.available() && allowed() && lifetime.accepts(lease.token)}
    private func configure(_ lease:Lease) {
        guard accepts(lease) else{return}
        let config=TelemetryWorkerConfiguration(demand:lease.demand,interval:Settings.intervalValue(defaults.double(forKey:Settings.interval)))
        worker.configure(config,token:lease.token,receive:{[weak self] reading,token in
            Task{@MainActor [weak self] in self?.receive(reading,token:token)}
        })
    }
    package func dismissError(){latest.error=nil;values.send(latest)}
    package func refreshCurrent(){guard let lease,accepts(lease) else{return};storedWorker?.refresh(lease.token)}
    package func preferencesDidChange(){if let lease{configure(lease)}}
    package func resetMenuBaselines(){
        guard let lease,accepts(lease) else{return}
        latest.menu = .init();storedWorker?.resetBaselines();publishMenu()
    }
    private func setDemand(_ demand:TelemetryDemand,lease:Lease) {
        guard accepts(lease),lease.demand != demand else{return}
        let wasVisible=lease.demand.visible;lease.demand=demand;latest.visible=demand.visible
        if demand.visible && !wasVisible,let snapshot=latest.latestSnapshot{publishSnapshot(snapshot,parts:latestParts);latest.history=buffer}
        values.send(latest);configure(lease)
    }
    private func receive(_ reading:TelemetryWorkerReading,token:UUID) {
        guard let lease,lease.token==token,accepts(lease) else{return}
        latest.menu=reading.menu
        if let model=reading.model{latest.model=model;latest.error=nil}
        if let error=reading.error{latest.error=error}
        if let snapshot=reading.snapshot {
            latest.latestSnapshot=snapshot;latestParts=reading.parts
            if let point=reading.history{buffer.append(point);buffer.removeAll{snapshot.timestamp.timeIntervalSince($0.time)>900}}
            if lease.demand.visible {
                if reading.resources{latest.memory=reading.memory;latest.disk=reading.disk}
                publishSnapshot(snapshot,parts:reading.parts);latest.history=buffer
            }
            checkAlert(snapshot)
        }
        if lease.demand.visible || reading.error != nil || reading.model != nil{values.send(latest)}
        publishMenu()
    }
    private func publishSnapshot(_ snapshot:Snapshot,parts:SamplerParts) {
        latest.fanReadingsUnavailable=parts.contains(.fans) && snapshot.fansAvailable == false
        let fans=parts.contains(.fans) && snapshot.hasFanReadings ? snapshot.fans:nil
        if let fans,lastFanSample != snapshot.timestamp {
            var streak:[Int:Int]=[:]
            for fan in fans where fan.rpm==0{streak[fan.id]=(fanZeroStreak[fan.id] ?? 0)+1}
            fanZeroStreak=streak;lastFanSample=snapshot.timestamp
            latest.stoppedFans=Set(streak.filter{$0.value>=3}.keys)
        }
        latest.sampledFans=fans;latest.snapshot=snapshot
    }
    private func publishMenu(){menu.send(.init(snapshot:latest.latestSnapshot,values:latest.menu,sampling:latest.sampling))}
    private func beginStopping(_ lease:Lease) {
        guard owns(lease),!lease.stopping else{return}
        lease.stopping=true;lifetime.stop();storedWorker?.stop()
        latest = .init();buffer=[];fanZeroStreak=[:];lastFanSample=nil;latestParts=[]
        values.send(latest);publishMenu()
    }
    private func finishStopping(_ lease:Lease) async {
        guard owns(lease) else{return}
        beginStopping(lease)
        await storedWorker?.finish()
        guard owns(lease) else{return}
        storedWorker=nil;self.lease=nil
    }
    package func shutdown(){if let lease{beginStopping(lease)}}
    private func checkAlert(_ snapshot:Snapshot) {
        guard Bundle.main.bundleIdentifier != nil,defaults.bool(forKey:Settings.alertsEnabled),
              let hot=snapshot.maximumKnownTemperature,hot>=Settings.thresholdValue(defaults.double(forKey:Settings.alertThreshold)),
              Date().timeIntervalSince(lastAlert)>300 else{return}
        lastAlert=Date();let fahrenheit=defaults.bool(forKey:Settings.fahrenheit),content=UNMutableNotificationContent()
        content.title=tr("Mac is running hot")
        content.body=tr(fahrenheit ? "Hottest sensor at %1$@ °F":"Hottest sensor at %1$@ °C",String(format:"%.0f",fahrenheit ? hot*9/5+32:hot))
            + (snapshot.fans.first.flatMap(\.rpm).map{tr(", fans at %1$@ rpm",String(format:"%.0f",$0))} ?? "")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier:"thermo.hot",content:content,trigger:nil))
    }
    @MainActor private final class Lease:TelemetrySamplingLease {
        weak var owner:CoreTelemetry?
        let token:UUID
        let available:@MainActor ()->Bool
        var demand=TelemetryDemand()
        var stopping=false
        init(owner:CoreTelemetry,token:UUID,available:@escaping @MainActor ()->Bool){self.owner=owner;self.token=token;self.available=available}
        func setDemand(_ demand:TelemetryDemand){owner?.setDemand(demand,lease:self)}
        func refresh(){guard let owner,owner.accepts(self) else{return};owner.storedWorker?.refresh(token)}
        func resetMenuBaselines(){guard let owner,owner.accepts(self) else{return};owner.resetMenuBaselines()}
        func beginStopping(){owner?.beginStopping(self)}
        func finishStopping() async{await owner?.finishStopping(self)}
    }
}
