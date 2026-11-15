import CleanKit
import Foundation
import NativeFeatureAPI
import SystemServicesAPI
import ThermoKit

struct TelemetryWorkerConfiguration {
    let demand:TelemetryDemand
    let interval:TimeInterval
}
struct TelemetryWorkerReading:Sendable {
    var snapshot:Snapshot?
    var parts:SamplerParts=[]
    var model:String?
    var error:String?
    var menu=MenuLiveValues()
    var memory:SystemStats.Memory?
    var disk:SystemStats.Disk?
    var history:HistoryPoint?
    var resources=false
}
/// Sole queue owner of the sensor sampler. Construction opens no hardware or timer.
final class TelemetryWorker:@unchecked Sendable {
    private let queue:DispatchQueue
    private let lifetime:FeatureSamplingLifetime
    private let allowed:@Sendable ()->Bool
    private let defaults:UserDefaults
    private let readOverride:(@Sendable (SamplingPlan)->Snapshot?)?
    private let counters:MenuLiveSampler
    private var sampler:Sampler?
    private var timer:DispatchSourceTimer?
    private var configuration=TelemetryWorkerConfiguration(demand:.init(),interval:2)
    private var receive:(@Sendable (TelemetryWorkerReading,UUID)->Void)?
    init(lifetime:FeatureSamplingLifetime,allowed:@escaping @Sendable ()->Bool,defaults:UserDefaults,
         queue:DispatchQueue? = nil,readOverride:(@Sendable (SamplingPlan)->Snapshot?)? = nil,
         counters:MenuLiveSampler? = nil) {
        self.lifetime=lifetime;self.allowed=allowed;self.defaults=defaults;self.readOverride=readOverride
        self.queue=queue ?? DispatchQueue(label:"dev.thermo.telemetry",qos:.utility)
        self.counters=counters ?? MenuLiveSampler(readCPU:QuickLoad.cpuTicks,cpuPercent:QuickLoad.cpuPercent)
    }
    func configure(_ configuration:TelemetryWorkerConfiguration,token:UUID,receive:@escaping @Sendable (TelemetryWorkerReading,UUID)->Void) {
        queue.async{
            guard self.lifetime.accepts(token),self.allowed() else{return}
            self.configuration=configuration;self.receive=receive
            self.timer?.cancel()
            let every=configuration.demand.visible ? configuration.interval:max(configuration.interval,2)
            let timer=DispatchSource.makeTimerSource(queue:self.queue)
            timer.schedule(deadline:.now(),repeating:every,leeway:.milliseconds(Int(every*100)))
            timer.setEventHandler{[weak self = self] in self?.sample(token)}
            timer.resume();self.timer=timer
        }
    }
    func refresh(_ token:UUID){queue.async{self.sample(token)}}
    func resetBaselines(){queue.async{self.counters.reset()}}
    func stop(){queue.async{self.timer?.cancel();self.timer=nil}}
    func finish() async {
        await withCheckedContinuation{done in queue.async{
            self.timer?.cancel();self.timer=nil;self.sampler=nil;self.counters.reset();self.receive=nil
            done.resume()
        }}
    }
    private func sample(_ token:UUID) {
        guard lifetime.accepts(token),allowed() else{return}
        let metrics=MenuBarPreferences.read(defaults).metrics
        var result=TelemetryWorkerReading()
        result.menu=counters.sample(metrics:metrics)
        let surface:SamplingSurface
        switch configuration.demand.surface{case .overview:surface = .overview;case .sensors:surface = .sensors;case .compact:surface = .compact}
        let plan=SamplingPlan.make(visible:configuration.demand.visible,includeUnnamed:configuration.demand.includeUnnamed,metrics:metrics,alerts:defaults.bool(forKey:Settings.alertsEnabled),surface:surface)
        result.parts=plan.parts
        guard !plan.parts.isEmpty else{receive?(result,token);return}
        let snapshot:Snapshot?
        if let readOverride{snapshot=readOverride(plan)}
        else {
            if sampler==nil {
                do {let made=try Sampler(scope:.essential);sampler=made;result.model=made.discovery.model}
                catch{result.error=String(describing:error);receive?(result,token);return}
            }
            guard let sampler else{return}
            sampler.scope=plan.scope;sampler.parts=plan.parts;sampler.groups=plan.groups
            snapshot=sampler.sample()
        }
        result.snapshot=snapshot
        if let snapshot {
            result.resources=configuration.demand.visible && surface == .overview
            if result.resources{result.memory=SystemStats.memory();result.disk=SystemStats.disk()}
            var averages=[Double](repeating:0,count:3)
            let load=getloadavg(&averages,3)>0 ? averages[0]/Double(max(1,ProcessInfo.processInfo.activeProcessorCount)):nil
            result.history = .init(time:snapshot.timestamp,cpu:snapshot.cpu,gpu:snapshot.gpu,fans:snapshot.fans.map(\.rpm),power:snapshot.systemPower,load:load)
        }
        receive?(result,token)
    }
    deinit{timer?.cancel()}
}
