import ModuleKit
import NativeFeatureAPI
import SwiftUI
import ThermoL10n

package enum ClaudeFeature {
    package static func registration()->NativeFeatureDefinition {
        .init(manifest:BuiltinModuleManifests.claude,ui:.init(sidebarLocations:[.agents]),resolveLegacyPage:{argument in
            let manifest=BuiltinModuleManifests.claude
            let scene:String
            if argument=="claude-cleanup" || argument.hasPrefix("claude-cleanup:") {scene=argument=="claude-cleanup:privacy" ? "claude:privacy":"claude:reset"}
            else if argument=="claude" {scene="claude:accounts"}
            else if argument.hasPrefix("claude:") {scene=manifest.entries.contains(where:{$0.scene==argument}) ? argument:"claude:accounts"}
            else{return nil}
            return manifest.entries.first{$0.kind == .page && $0.scene==scene}.map{.init(manifest.id,$0.id)}
        },makeSession:{ClaudeSession(availability:$0)})
    }
}
@MainActor final class ClaudeSession:NativeFeatureSession {
    private let availability:FeatureAvailability
    private let makeAccounts:@MainActor (@escaping ()->Bool)->ClaudeAccountsModel
    private let makeCleanup:@MainActor (@escaping ()->Bool)->ClaudeCleanupModel
    private var accounts:ClaudeAccountsModel?
    private var cleanup:ClaudeCleanupModel?
    init(availability:FeatureAvailability,
         makeAccounts:@escaping @MainActor (@escaping ()->Bool)->ClaudeAccountsModel = {ClaudeAccountsModel(enabled:$0)},
         makeCleanup:@escaping @MainActor (@escaping ()->Bool)->ClaudeCleanupModel = {ClaudeCleanupModel(enabled:$0)}) {
        self.availability=availability;self.makeAccounts=makeAccounts;self.makeCleanup=makeCleanup
    }
    func ui(_ surface:NativeUISurface,navigation:NativeNavigation)->AnyView? {
        guard availability.acceptsWork,case let .sidebar(location,selection,rows)=surface,location == .agents else{return nil}
        return AnyView(ForEach(BuiltinModuleManifests.claude.entries.filter{$0.kind == .page && ($0.parent == nil || selection?.module==BuiltinModuleManifests.claude.id)},id:\.id){entry in
            rows(.init(route:.init(BuiltinModuleManifests.claude.id,entry.id),tint:.orange))
        })
    }
    func page(_ route:NativeFeatureRoute,navigation:NativeNavigation)->AnyView? {
        let entry=route.entry
        guard availability.acceptsWork,let tab=ClaudeTab(rawValue:entry) else{return nil}
        let availability=availability
        switch tab {
        case .accounts:
            if accounts==nil {accounts=makeAccounts{availability.acceptsWork}}
            return accounts.map{AnyView(ClaudeAccountsPage(model:$0))}
        case .reset,.privacy:
            if cleanup==nil {cleanup=makeCleanup{availability.acceptsWork}}
            return cleanup.map{AnyView(ClaudeCleanupPage(model:$0,tab:tab).id(tab))}
        }
    }
    var status:NativeFeatureStatus {
        .init(modelLoaded:accounts != nil || cleanup != nil,snapshotReady:accounts?.loaded == true || (cleanup?.loaded == true && cleanup?.busy == false))
    }
    func retireVisibility() {}
    func quitBlocker()->NativeFeatureBlocker? {
        guard let cleanup,!cleanup.canStopFeature else{return nil}
        return .init(reason:tr("Wait for Claude reset, recovery or privacy changes before switching this feature off."),route:.init(BuiltinModuleManifests.claude.id,cleanup.privacyOperationRunning ? "privacy":"reset"))
    }
    func prepareStop()throws->NativeFeatureDrain {
        guard cleanup?.canStopFeature != false else{throw NativeFeatureBusy(tr("Wait for Claude reset, recovery or privacy changes before switching this feature off."))}
        let accounts=accounts,cleanup=cleanup
        accounts?.stopFeature();cleanup?.stopFeature()
        return .init { [weak self] in
            await accounts?.finishFeatureStop();await cleanup?.finishFeatureStop()
            if self?.accounts === accounts {self?.accounts=nil}
            if self?.cleanup === cleanup {self?.cleanup=nil}
        }
    }
}
