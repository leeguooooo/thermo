import Combine
import Foundation
import ThermoKit

package enum TelemetrySurface:Sendable {case overview,sensors,compact}
package struct TelemetryDemand:Sendable,Equatable {
    package var visible:Bool
    package var surface:TelemetrySurface
    package var includeUnnamed:Bool
    package init(visible:Bool = false,surface:TelemetrySurface = .overview,includeUnnamed:Bool = false){self.visible=visible;self.surface=surface;self.includeUnnamed=includeUnnamed}
}
package struct SensorHistoryPoint:Identifiable,Sendable {
    package let time:Date
    package let cpu:Double?,gpu:Double?
    package let fans:[Double?]
    package let power:Double?,load:Double?
    package var id:Date{time}
    package init(time:Date,cpu:Double?,gpu:Double?,fans:[Double?],power:Double?,load:Double? = nil){self.time=time;self.cpu=cpu;self.gpu=gpu;self.fans=fans;self.power=power;self.load=load}
}
package struct MenuLiveReading:Sendable {
    package var sampled=Date.distantPast
    package var cpu:Double?,memory:Double?,download:Double?,upload:Double?
    package init(sampled:Date = .distantPast,cpu:Double? = nil,memory:Double? = nil,download:Double? = nil,upload:Double? = nil){self.sampled=sampled;self.cpu=cpu;self.memory=memory;self.download=download;self.upload=upload}
}
/// A value from the unique core producer. Consumers cannot mutate its authority or create a sampler.
package struct TelemetryReading:Sendable {
    package var snapshot:Snapshot?
    package var latestSnapshot:Snapshot?
    package var sampledFans:[FanReading]?
    package var fanReadingsUnavailable=false
    package var stoppedFans:Set<Int>=[]
    package var history:[SensorHistoryPoint]=[]
    package var memory:SystemStats.Memory?
    package var disk:SystemStats.Disk?
    package var model=""
    package var error:String?
    package var menu=MenuLiveReading()
    package var visible=false
    package var sampling=false
    package init(){}
}
package struct MenuTelemetryReading:Sendable {
    package let snapshot:Snapshot?
    package let values:MenuLiveReading
    package let sampling:Bool
    package init(snapshot:Snapshot?,values:MenuLiveReading,sampling:Bool){self.snapshot=snapshot;self.values=values;self.sampling=sampling}
}
@MainActor package protocol TelemetrySamplingLease:AnyObject {
    func setDemand(_ demand:TelemetryDemand)
    func refresh()
    func resetMenuBaselines()
    func beginStopping()
    func finishStopping() async
}
@MainActor package protocol TelemetryReadService:AnyObject {
    var latest:TelemetryReading{get}
    /// Visible presentation updates; hidden status ticks do not redraw retained feature views.
    var readings:AnyPublisher<TelemetryReading,Never>{get}
    /// Passive derived values for the shell. Subscribing never acquires sampling demand.
    var menuReadings:AnyPublisher<MenuTelemetryReading,Never>{get}
    func beginPerformanceSampling(available:@escaping @MainActor ()->Bool)throws->any TelemetrySamplingLease
}
