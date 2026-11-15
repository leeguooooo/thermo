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
package struct HistoryPoint:Identifiable,Sendable {
    package let time:Date
    package let cpu:Double?,gpu:Double?
    package let fans:[Double?]
    package let power:Double?,load:Double?
    package var id:Date{time}
    package init(time:Date,cpu:Double?,gpu:Double?,fans:[Double?],power:Double?,load:Double? = nil){self.time=time;self.cpu=cpu;self.gpu=gpu;self.fans=fans;self.power=power;self.load=load}
}
/// A value from the unique core producer. Consumers cannot mutate its authority or create a sampler.
package struct TelemetryReading:Sendable {
    package var snapshot:Snapshot?
    package var latestSnapshot:Snapshot?
    package var sampledFans:[FanReading]?
    package var fanReadingsUnavailable=false
    package var stoppedFans:Set<Int>=[]
    package var history:[HistoryPoint]=[]
    package var memory:SystemStats.Memory?
    package var disk:SystemStats.Disk?
    package var model=""
    package var error:String?
    package var menu=MenuLiveValues()
    package var visible=false
    package var sampling=false
    package init(){}
}
package struct MenuTelemetryReading:Sendable {
    package let snapshot:Snapshot?
    package let values:MenuLiveValues
    package let sampling:Bool
    package init(snapshot:Snapshot?,values:MenuLiveValues,sampling:Bool){self.snapshot=snapshot;self.values=values;self.sampling=sampling}
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
    func dismissError()
    /// Requests an existing admitted producer; this never acquires sampling authority.
    func refreshCurrent()
    func preferencesDidChange()
    func resetMenuBaselines()
    func beginPerformanceSampling(available:@escaping @MainActor ()->Bool)throws->any TelemetrySamplingLease
}
