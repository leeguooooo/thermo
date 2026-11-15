import AgentCore
import Combine
import Foundation
import ServiceManagement
import SystemServicesAPI
import ThermoKit
import ThermoL10n
import UserNotifications

protocol KernelHelperTransport:Sendable {
    func version() async throws->String
    func fanControlState() async throws->FanControlState
    func lidAwakeState() async throws->LidAwakeState
    func setPolicy(_ policy:FanPolicy,fan:Int) async throws
    func setLidAwake(_ on:Bool,heatGuard:Bool) async throws
    func withRemovalPreparation(_ remove:()throws->Void)throws
    func reset()
}
extension HelperClient:KernelHelperTransport{}

/// Helper administration outlives optional UI; observation clients carry their own admission epoch.
@MainActor package final class CoreHelperAdministration:HelperAdministration,FanPolicyAccessFactory {
    private let helper:any KernelHelperTransport
    private let automaticInteraction:Bool
    private let daemon=SMAppService.daemon(plistName:HelperConstants.bundledPlistName)
    private let beginMaintenance:()->UUID
    private let endMaintenance:(UUID)->Void
    private let fans:()->[FanReading]
    private let refreshTelemetry:()->Void
    private let recordFan:([(Int,FanPolicy)],[Int:FanPolicy]?,String?,[FanReading])->Void
    private let values=CurrentValueSubject<HelperReading,Never>(.init())
    private var state=HelperReading(){didSet{values.send(state)}}
    private var pendingOwners:[Int:Client]=[:]
    private var policyRevision=0
    private var query:Task<Void,Never>?
    private var refreshAdminAgain=false
    private var setupTimer:Timer?
    private let upgrade=HelperUpgradeCoordinator()
    package var latest:HelperReading{state}
    package var readings:AnyPublisher<HelperReading,Never>{values.eraseToAnyPublisher()}
    package convenience init(helper:HelperClient = .init(),automaticInteractionAllowed:Bool,
                             beginMaintenance:@escaping @MainActor ()->UUID,endMaintenance:@escaping @MainActor (UUID)->Void,
                             fans:@escaping @MainActor ()->[FanReading] = {[]},refreshTelemetry:@escaping @MainActor ()->Void = {}) {
        self.init(transport:helper,automaticInteractionAllowed:automaticInteractionAllowed,usesSMAppService:CodeSignature.teamIdentifier() != nil,
                  beginMaintenance:beginMaintenance,endMaintenance:endMaintenance,fans:fans,refreshTelemetry:refreshTelemetry)
    }
    init(transport:any KernelHelperTransport,automaticInteractionAllowed:Bool,usesSMAppService:Bool,
         beginMaintenance:@escaping @MainActor ()->UUID,endMaintenance:@escaping @MainActor (UUID)->Void,
         fans:@escaping @MainActor ()->[FanReading] = {[]},refreshTelemetry:@escaping @MainActor ()->Void = {},
         recordFan:@escaping @MainActor ([(Int,FanPolicy)],[Int:FanPolicy]?,String?,[FanReading])->Void = {FanPolicyJournal.record($0,active:$1,error:$2,fans:$3)}) {
        helper=transport;automaticInteraction=automaticInteractionAllowed;self.beginMaintenance=beginMaintenance;self.endMaintenance=endMaintenance
        self.fans=fans;self.refreshTelemetry=refreshTelemetry;self.recordFan=recordFan
        state.usesSMAppService=usesSMAppService
    }
    package func bind(available:@escaping @MainActor ()->Bool)->any FanPolicyAccess{Client(owner:self,available:available)}
    private func valid(_ revision:Int,origin:Client?)->Bool{revision==policyRevision && !state.busy && (origin?.accepts ?? true) && !Task.isCancelled}
    package func refresh(){refresh(origin:nil)}
    private func refresh(origin:Client?) {
        guard automaticInteraction,origin?.accepts ?? true,!state.busy else{return}
        if query != nil{if origin==nil{refreshAdminAgain=true};return}
        let revision=policyRevision,id=UUID()
        let task=Task{@MainActor in
            defer{
                query=nil;origin?.tasks[id]=nil
                let again=refreshAdminAgain;refreshAdminAgain=false
                if again{refresh()}
            }
            guard valid(revision,origin:origin) else{return}
            if let version=try? await helper.version() {
                guard valid(revision,origin:origin) else{return}
                let control=try? await helper.fanControlState()
                guard valid(revision,origin:origin) else{return}
                let lid=version==HelperConstants.version ? try? await helper.lidAwakeState():nil
                guard valid(revision,origin:origin) else{return}
                state.fanControl=control;state.policiesAvailable=control != nil
                if let control{state.policies=control.policies}
                state.phase=version==HelperConstants.version ? .running:.outdated
                observeLid(lid)
                guard valid(revision,origin:origin) else{return}
                if state.phase == .outdated{restartOutdatedHelper(origin:origin)}
                finishSetup();return
            }
            guard valid(revision,origin:origin) else{return}
            state.policiesAvailable=false;state.fanControl=nil
            if state.usesSMAppService {
                switch daemon.status {
                case .requiresApproval:state.phase = .needsApproval
                case .enabled:
                    let refused=await Task.detached{Self.launchdRefusesHelper()}.value
                    guard valid(revision,origin:origin) else{return}
                    state.phase=refused ? .needsApproval:.notRunning
                default:state.phase=HelperInstaller.isInstalled ? .notRunning:.notInstalled
                }
            } else{state.phase=HelperInstaller.isInstalled ? .notRunning:.notInstalled}
        }
        query=task;origin?.tasks[id]=task
    }
    private func beginSetup(origin:Client?) {
        guard origin?.accepts ?? true,!state.settingUp,!state.busy else{return}
        state.settingUp=true;state.setupStarted=Date()
        Task{@MainActor in
            let version=try? await helper.version()
            guard origin?.accepts ?? true else{stopSetup();return}
            if version != nil{refresh(origin:origin);return}
            if state.usesSMAppService,daemon.status == .enabled {
                let refused=await Task.detached{Self.launchdRefusesHelper()}.value
                guard origin?.accepts ?? true else{stopSetup();return}
                if !refused{watchSetup();return}
            }
            continueInstallation()
        }
    }
    private func watchSetup(){
        setupTimer?.invalidate()
        setupTimer=Timer.scheduledTimer(withTimeInterval:1,repeats:true){[weak self] timer in MainActor.assumeIsolated{
            guard let self else{timer.invalidate();return}
            if let start=self.state.setupStarted,Date().timeIntervalSince(start)>600{
                self.stopSetup();self.state.error=tr("The system helper did not respond. Your settings have not been applied. Retry setup when ready.");return
            }
            self.refresh()
        }}
    }
    package func stopSetup(){setupTimer?.invalidate();setupTimer=nil;state.settingUp=false;state.setupStarted=nil}
    private func finishSetup(){
        guard !state.busy else{return}
        guard [.running,.outdated].contains(state.phase) else{stopSetup();return}
        stopSetup()
        let pending=state.pendingPolicies.filter{pendingOwners[$0.key]?.accepts ?? true}
        state.pendingPolicies=[:];pendingOwners=[:]
        if !pending.isEmpty{applyPolicies(pending.sorted{$0.key<$1.key})}
        if state.lidAwakePending,state.phase == .running{state.lidAwakePending=false;setLidAwake(true)}
    }
    package func setLidAwake(_ on:Bool){
        guard !state.lidAwakeBusy else{return}
        guard state.phase == .running else{state.lidAwakePending=on;if on && !state.settingUp{beginSetup(origin:nil)};return}
        state.lidAwakeBusy=true
        Task{@MainActor in
            defer{state.lidAwakeBusy=false}
            do{
                let guardHeat=UserDefaults.standard.bool(forKey:Settings.lidAwakeHeatGuard)
                try await helper.setLidAwake(on,heatGuard:guardHeat)
                OperationJournal.record(OperationRecord(feature:"power",action:on ? "lidAwakeOn":"lidAwakeOff",items:[.init(target:"disablesleep",status:"done",detail:on && !guardHeat ? "heat guard off":nil)]))
            }catch{
                state.error=tr("Could not change lid-closed sleep: %1$@",error.localizedDescription)
                OperationJournal.record(OperationRecord(feature:"power",action:on ? "lidAwakeOn":"lidAwakeOff",items:[.init(target:"disablesleep",status:"failed",detail:error.localizedDescription)]))
            }
            observeLid(try? await helper.lidAwakeState())
        }
    }
    private func observeLid(_ lid:LidAwakeState?){
        let before=state.lidAwake;state.lidAwake=lid
        guard let lid,let off=lid.lastAutoOff,off != before?.lastAutoOff,before?.armed == true,!lid.armed else{return}
        OperationJournal.record(OperationRecord(feature:"power",action:"lidAwakeAutoOff",subject:off.reason,items:[.init(target:"disablesleep",status:"done",detail:off.detail)]))
        guard Bundle.main.bundleIdentifier != nil else{return}
        let content=UNMutableNotificationContent();content.title=tr("Lid-closed awake turned off")
        content.body=LidAwakeText.autoOff(off)+" "+tr("The Mac can sleep again when the lid is closed.")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier:"thermo.lidawake",content:content,trigger:nil))
    }
    package func install(){beginSetup(origin:nil)}
    package func installWithPassword(){guard !state.busy,!state.settingUp else{return};continueInstallation()}
    private func continueInstallation(){
        guard !state.busy else{return}
        guard let binary=HelperInstaller.locateHelperBinary() else{state.error=tr("thermo-helper not found inside the app bundle");stopSetup();return}
        let managed=state.usesSMAppService,daemon=daemon
        performInstallation(operation:{
            if managed && !HelperInstaller.isInstalled && daemon.status != .notRegistered{try? daemon.unregister()}
            try HelperInstaller.install(from:binary)
        })
    }
    func performInstallation(operation:@escaping ()throws->Void,finished:@escaping ()->Void = {}){
        guard !state.busy else{return}
        state.settingUp=true;state.installing=true;policyRevision+=1;state.setupStarted=state.setupStarted ?? Date()
        let token=beginMaintenance()
        DispatchQueue.global(qos:.userInitiated).async{
            var failure:String?;do{try operation()}catch{failure=String(describing:error)}
            let error=failure
            Task{@MainActor in
                self.endMaintenance(token);self.state.installing=false
                if let error{self.state.error=error.contains("cancelled") ? nil:error;self.stopSetup()}
                else{self.helper.reset();self.state.error=nil;self.watchSetup()}
                finished()
            }
        }
    }
    nonisolated static func launchdRefusesHelper()->Bool{
        let result=CommandRunner.run("/bin/launchctl",arguments:["print","system/\(HelperConstants.label)"],timeout:5,captureError:false)
        return result.status==0 && !result.timedOut && !result.cancelled && !result.truncated && (result.output.contains("last exit code = 78") || result.output.contains("job state = spawn failed"))
    }
    private func restartOutdatedHelper(origin:Client?){
        guard origin?.accepts ?? true,!HelperInstaller.isInstalled,state.usesSMAppService,daemon.status == .enabled,!upgrade.attempted,!state.busy else{return}
        state.installing=true;policyRevision+=1
        Task{@MainActor in
            do{
                let restarted=try await upgrade.restartManaged(legacyInstalled:HelperInstaller.isInstalled,unregister:{try await self.daemon.unregister()},register:{try self.daemon.register()})
                if !restarted{state.installing=false;return}
            }catch{state.error=tr("Helper update: %1$@",error.localizedDescription)}
            if daemon.status == .requiresApproval{SMAppService.openSystemSettingsLoginItems()}
            try? await Task.sleep(nanoseconds:2_000_000_000);state.installing=false;refresh()
        }
    }
    private func request(_ policy:FanPolicy,fans:[Int],origin:Client?){
        guard origin?.accepts ?? true,!state.busy,!fans.isEmpty else{return}
        do{try policy.validate()}catch{state.error=String(describing:error);return}
        let changes=Set(fans).sorted().map{($0,policy)}
        guard [.running,.outdated].contains(state.phase) else{
            for (fan,policy) in changes{state.pendingPolicies[fan]=policy;if let origin{pendingOwners[fan]=origin}else{pendingOwners[fan]=nil}}
            if !state.settingUp{beginSetup(origin:origin)};return
        }
        applyPolicies(changes)
    }
    private func applyPolicies(_ changes:[(Int,FanPolicy)]){
        guard !state.busy else{return}
        state.applyingPolicies=true;policyRevision+=1
        Task{@MainActor in
            var observed:FanControlState?
            let result=await FanPolicyOperation.run(changes,set:{try await self.helper.setPolicy($0,fan:$1)},read:{let value=try await self.helper.fanControlState();observed=value;return value.policies})
            state.fanControl=observed;if let policies=result.policies{state.policies=policies};state.policiesAvailable=result.policies != nil
            recordFan(changes,result.policies,result.error,fans());state.error=result.error ?? observed?.failure
            state.applyingPolicies=false;refreshTelemetry();if result.policies==nil{refresh()}
        }
    }
    package func restoreAutomaticFans(_ fans:[Int]){request(.auto,fans:fans,origin:nil)}
    package func openLoginItemsSettings(){SMAppService.openSystemSettingsLoginItems()}
    package func uninstall(finished:@escaping @MainActor ()->Void){
        let daemon=daemon,managed=state.usesSMAppService,helper=helper
        performUninstallation(operation:{
            if HelperInstaller.isInstalled{try HelperInstaller.uninstall()}
            else if managed && daemon.status != .notRegistered{
                try helper.withRemovalPreparation{try daemon.unregister();guard daemon.status == .notRegistered else{throw FanControlError.helper("helper background registration removal was not confirmed")}}
            }else{throw FanControlError.helper("no helper registration could be verified; nothing was removed")}
        },finished:finished)
    }
    func performUninstallation(operation:@escaping ()throws->Void,finished:@escaping ()->Void = {}){
        guard !state.busy,!state.settingUp else{return}
        state.uninstalling=true;let token=beginMaintenance();policyRevision+=1;state.policiesAvailable=false;state.fanControl=nil
        stopSetup();state.pendingPolicies=[:];pendingOwners=[:]
        DispatchQueue.global(qos:.userInitiated).async{
            var failure:String?;do{try operation()}catch{failure=String(describing:error)}
            let error=failure
            Task{@MainActor in
                self.endMaintenance(token);self.state.uninstalling=false;self.state.error=error;self.helper.reset()
                if error==nil{self.state.policies=[:]};self.refresh();finished()
            }
        }
    }
    @MainActor private final class Client:FanPolicyAccess {
        weak var owner:CoreHelperAdministration?
        let available:()->Bool
        var retiring=false
        var tasks:[UUID:Task<Void,Never>]=[:]
        var accepts:Bool{!retiring && available()}
        init(owner:CoreHelperAdministration,available:@escaping ()->Bool){self.owner=owner;self.available=available}
        var latest:HelperReading{owner?.latest ?? .init()}
        var readings:AnyPublisher<HelperReading,Never>{owner?.readings ?? Empty<HelperReading,Never>().eraseToAnyPublisher()}
        func request(_ policy:FanPolicy,fans:[Int]){guard accepts else{return};owner?.request(policy,fans:fans,origin:self)}
        func refreshObservation(){guard accepts else{return};owner?.refresh(origin:self)}
        func beginRetiring(){retiring=true;for task in tasks.values{task.cancel()}}
        func finishRetiring() async{beginRetiring();while let task=tasks.values.first{await task.value}}
    }
}
