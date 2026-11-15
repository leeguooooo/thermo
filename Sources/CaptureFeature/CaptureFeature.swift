import CaptureScriptCore
import ModuleKit
import NativeFeatureAPI
import SwiftUI
import ThermoL10n
import ThermoUI

package struct CaptureControlRequest:Sendable {
    package enum Operation:Sendable {case actions,status(UUID?),cancel(UUID?),run(String),action(String)}
    package let id:UUID
    package let operation:Operation
    package let dryRun:Bool
    package init(id:UUID,operation:Operation,dryRun:Bool = false){self.id=id;self.operation=operation;self.dryRun=dryRun}
}
/// Request success is separate from a queried operation's recorded phase.
package struct CaptureControlResult:Sendable {
    package let report:CaptureCLIReport
    package let succeeded:Bool
    package init(report:CaptureCLIReport,succeeded:Bool){self.report=report;self.succeeded=succeeded}
}
@MainActor package protocol CaptureApplicationControl:AnyObject {
    func handle(_ request:CaptureControlRequest) async->CaptureControlResult
    func cancelActive()
}
package struct CaptureRegistration:Sendable {
    package let definition:NativeFeatureDefinition
    package let makeControl:@MainActor @Sendable (NativeFeatureStore)->any CaptureApplicationControl
}
package enum CaptureFeature {
    package static func registration()->CaptureRegistration {makeRegistration()}
    static func makeRegistration(makeWorkspace:@escaping CaptureSession.WorkspaceFactory = {availability in CaptureWorkspace(featureEnabled:{availability.acceptsWork})})->CaptureRegistration {
        let hub=CaptureControlHub()
        let definition=NativeFeatureDefinition(manifest:BuiltinModuleManifests.capture,ui:.init(hasMenuContent:true),makeSession:{availability in
            let session=CaptureSession(availability:availability,hub:hub,makeWorkspace:makeWorkspace);hub.current=session;return session
        })
        return .init(definition:definition,makeControl:{CaptureControlAccess(store:$0,hub:hub)})
    }
}
/// Only the bounded request ledger survives generations; it owns no cold workspace.
final class CaptureControlHub:@unchecked Sendable {
    @MainActor weak var current:CaptureSession?
    @MainActor private var storedLedger:CaptureCLIHost?
    @MainActor var ledger:CaptureCLIHost {
        if let storedLedger{return storedLedger};let value=CaptureCLIHost();storedLedger=value;return value
    }
    @MainActor func clear(_ session:CaptureSession){if current === session{current=nil}}
}
@MainActor struct CaptureExecutionAccess {
    let canUse:()->Bool
    let workspace:()->CaptureWorkspace?
}
@MainActor private final class CaptureControlAccess:CaptureApplicationControl {
    let store:NativeFeatureStore
    let hub:CaptureControlHub
    init(store:NativeFeatureStore,hub:CaptureControlHub){self.store=store;self.hub=hub}
    func handle(_ request:CaptureControlRequest) async->CaptureControlResult {
        let ref=NativeUIEntryRef(BuiltinModuleManifests.capture.id,"tools")
        return await hub.ledger.handle(request,access:.init(canUse:{[store] in store.canAdmitUIEntryOwner(ref)},workspace:{[store,hub] in
            guard store.admitUIEntryOwner(ref),let session=hub.current,session.availability.acceptsWork else{return nil}
            return session.workspace
        }))
    }
    func cancelActive(){hub.ledger.cancelActive()}
}

@MainActor final class CaptureSession:NativeFeatureSession {
    typealias WorkspaceFactory = @MainActor (FeatureAvailability)->CaptureWorkspace
    let availability:FeatureAvailability
    private let hub:CaptureControlHub
    private let makeWorkspace:WorkspaceFactory
    private(set) var storedWorkspace:CaptureWorkspace?
    private var termination:NativeTerminationTicket?
    init(availability:FeatureAvailability,hub:CaptureControlHub,makeWorkspace:@escaping WorkspaceFactory){self.availability=availability;self.hub=hub;self.makeWorkspace=makeWorkspace}
    var workspace:CaptureWorkspace {
        if let storedWorkspace{return storedWorkspace};let made=makeWorkspace(availability);storedWorkspace=made;return made
    }
    func start(){guard availability.acceptsWork else{return};workspace.activate()}
    func page(_ route:NativeFeatureRoute,navigation:NativeNavigation)->AnyView?{nil}
    var status:NativeFeatureStatus{.init(modelLoaded:storedWorkspace != nil,sampling:storedWorkspace.map{$0.captureBusy || $0.scriptRunning || $0.nativeScriptBusy || $0.recordingActive} == true)}
    func menuContent(_ ref:NativeUIEntryRef)->NativeMenuContent? {
        guard ref == .init(BuiltinModuleManifests.capture.id,"tools"),availability.acceptsWork else{return nil}
        return CaptureMenuPresentation.content(workspace:workspace,available:{[availability] in availability.acceptsWork})
    }
    func activate(_ ref:NativeUIEntryRef,navigation:NativeNavigation)->Bool {
        guard availability.acceptsWork,ref.module==BuiltinModuleManifests.capture.id else{return false}
        switch ref.entry {
        case "saving":workspace.showSavingSettings()
        case "shortcuts":workspace.showActionSettings()
        default:return false
        }
        return true
    }
    func ui(_ surface:NativeUISurface,navigation:NativeNavigation)->AnyView? {
        guard availability.acceptsWork else{return nil}
        switch surface {
        case let .inlineSettings(ref):
            guard ref.module==BuiltinModuleManifests.capture.id,let entry=BuiltinModuleManifests.capture.entries.first(where:{$0.id==ref.entry && $0.kind == .settingsItem}) else{return nil}
            return AnyView(HStack(spacing:Theme.Space.m){
                Image(systemName:entry.symbol ?? "viewfinder").frame(width:22).foregroundStyle(Theme.textSecondary)
                Text(tr(entry.title)).font(Theme.body);Spacer()
                Button(tr("Open")){[weak self] in _=self?.activate(ref,navigation:.unavailable)}.buttonStyle(PillButtonStyle()).controlSize(.small)
            }.padding(.horizontal,Theme.Space.m).padding(.vertical,8))
        case let .renderPreview(ref):
            guard ref.module==BuiltinModuleManifests.capture.id else{return nil}
            if ref.entry=="saving"{return AnyView(CaptureSaveSettingsView(model:workspace.saving))}
            if ref.entry=="shortcuts"{return AnyView(CaptureActionSettingsView(model:workspace.shortcuts))}
            return nil
        default:return nil
        }
    }
    func prepareTermination()->NativeTerminationDecision {
        if let termination,!termination.resolved{return .deferred(termination)}
        guard let workspace=storedWorkspace else{return .allow}
        let decision=workspace.prepareTermination()
        if case let .deferred(ticket)=decision{termination=ticket}else{termination=nil}
        return decision
    }
    func prepareStop()throws->NativeFeatureDrain {
        guard termination?.resolved != false else{throw NativeFeatureBusy(tr("Finish the current capture, recording or export before switching this feature off."))}
        let workspace=storedWorkspace
        try workspace?.stopFeature()
        return .init{[self] in
            await workspace?.finishFeatureStop()
            storedWorkspace=nil;hub.clear(self)
        }
    }
    func retireVisibility(){}
    func quitBlocker()->NativeFeatureBlocker?{nil}
    func shutdown(){storedWorkspace?.shutdown()}
}
