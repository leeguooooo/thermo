import Combine
import Foundation
import SystemServicesAPI
import ThermoKit

/// Shell-only projection of the app's shared services; it cannot acquire an optional reader.
@MainActor final class SystemPresentation: ObservableObject {
    private let telemetry: any TelemetryReadService
    let administration: any HelperAdministration
    private var observations=Set<AnyCancellable>()
    private var lastSnapshot:Date?
    @Published var iconHidden=false
    @Published var popoverOpen=false
    @Published var windowOpen=false
    var onUpdate:((Snapshot)->Void)?
    var onMenuUpdate:(()->Void)?
    init(telemetry:any TelemetryReadService,administration:any HelperAdministration){
        self.telemetry=telemetry;self.administration=administration
        telemetry.readings.sink{[weak self] _ in self?.objectWillChange.send()}.store(in:&observations)
        administration.readings.sink{[weak self] _ in self?.objectWillChange.send()}.store(in:&observations)
        telemetry.menuReadings.sink{[weak self] value in
            guard let self else{return}
            if let snapshot=value.snapshot,self.lastSnapshot != snapshot.timestamp{self.lastSnapshot=snapshot.timestamp;self.onUpdate?(snapshot)}
            self.onMenuUpdate?()
        }.store(in:&observations)
    }
    var snapshot:Snapshot?{telemetry.latest.latestSnapshot}
    var latest:Snapshot?{telemetry.latest.latestSnapshot}
    var menuLive:MenuLiveValues{telemetry.latest.menu}
    var helperState:HelperState{administration.latest.phase}
    var helperBusy:Bool{administration.latest.busy}
    var installingHelper:Bool{administration.latest.installing}
    var uninstallingHelper:Bool{administration.latest.uninstalling}
    var settingUp:Bool{administration.latest.settingUp}
    var lidAwake:LidAwakeState?{administration.latest.lidAwake}
    var lidAwakePending:Bool{administration.latest.lidAwakePending}
    var lidAwakeBusy:Bool{administration.latest.lidAwakeBusy}
    var lastError:String?{
        get{administration.latest.error ?? telemetry.latest.error}
        set{if newValue == nil{administration.dismissError();telemetry.dismissError()}}
    }
    func sampleNow(){telemetry.refreshCurrent()}
    func reschedule(){telemetry.preferencesDidChange()}
    func resetMenuBaselines(){telemetry.resetMenuBaselines()}
    func refreshHelper(){administration.refresh()}
    func stopSetup(){administration.stopSetup()}
    func installHelper(){administration.install()}
    func installHelperWithPassword(){administration.installWithPassword()}
    func uninstallHelper(finished:@escaping ()->Void = {}){administration.uninstall(finished:finished)}
    func setLidAwake(_ on:Bool){administration.setLidAwake(on)}
    nonisolated static func requestNotificationPermission(){Task{@MainActor in NotificationAccess.shared.request()}}
}
