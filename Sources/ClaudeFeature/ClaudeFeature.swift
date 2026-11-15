import ModuleKit
import NativeFeatureAPI
import SwiftUI
import ThermoL10n

package enum ClaudeFeature {
    package static func registration()->NativeFeatureDefinition {
        .init(manifest:BuiltinModuleManifests.claude,makeSession:{ClaudeSession(availability:$0)})
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
    func page(entry:String)->AnyView? {
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
