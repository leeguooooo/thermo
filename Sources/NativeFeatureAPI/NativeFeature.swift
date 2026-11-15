import Foundation
import ModuleKit
import SwiftUI

package struct NativeFeatureRoute:Hashable,Sendable {
    package let module:String
    package let entry:String
    package let context:[String:NativeContextValue]
    package init(_ module:String,_ entry:String,context:[String:NativeContextValue] = [:]) {self.module=module;self.entry=entry;self.context=context}
}
@MainActor package final class FeatureAvailability {
    private let enabled:()->Bool
    private var revoked=false
    package init(enabled:@escaping ()->Bool) {self.enabled=enabled}
    package var acceptsWork:Bool {!revoked && enabled()}
    func revoke(){revoked=true}
}
package struct NativeFeatureStatus {
    package var modelLoaded:Bool
    package var sampling:Bool
    package var snapshotReady:Bool
    package init(modelLoaded:Bool = false,sampling:Bool = false,snapshotReady:Bool = false) {
        self.modelLoaded=modelLoaded;self.sampling=sampling;self.snapshotReady=snapshotReady
    }
}
package struct NativeFeatureBlocker {
    package let reason:String
    package let route:NativeFeatureRoute
    package init(reason:String,route:NativeFeatureRoute) {self.reason=reason;self.route=route}
}
package struct NativeFeatureBusy:Error,LocalizedError,CustomStringConvertible {
    package let description:String
    package init(_ reason:String){description=reason}
    package var errorDescription:String?{description}
}
@MainActor package struct NativeFeatureDrain {
    package let finish:() async->Void
    package init(finish:@escaping () async->Void){self.finish=finish}
}
/// Native feature implementations own models; callers see only UI and lifecycle contributions.
@MainActor package protocol NativeFeatureSession:AnyObject {
    func ui(_ surface:NativeUISurface,navigation:NativeNavigation)->AnyView?
    func page(_ route:NativeFeatureRoute,navigation:NativeNavigation)->AnyView?
    var status:NativeFeatureStatus {get}
    func start()
    func shutdown()
    func invalidateAfterRestore(_ paths:[String])
    func retireVisibility()
    func quitBlocker()->NativeFeatureBlocker?
    func preparePresentation(_ route:NativeFeatureRoute,options:[String:NativeContextValue])
    func prepareReview(_ route:NativeFeatureRoute,arguments:[String])
    func snapshotReady(_ route:NativeFeatureRoute,arguments:[String],started:Date)->Bool
    func activate(_ entry:NativeUIEntryRef,navigation:NativeNavigation)->Bool
    func prepareStop()throws->NativeFeatureDrain
}
package struct NativeFeatureDefinition:Sendable {
    package let manifest:ModuleManifest
    package let pageContracts:[NativePageContract]
    package let ui:NativeUIContributions
    package let menuShortcuts:[String:String]
    let resolveLegacyPage:@Sendable (String)->NativeFeatureRoute?
    let invalidateColdState:@MainActor @Sendable ([String])->Void
    let makeSession:@MainActor @Sendable (FeatureAvailability)->any NativeFeatureSession
    package init(manifest:ModuleManifest,pageContracts:[NativePageContract] = [],ui:NativeUIContributions = .none,menuShortcuts:[String:String] = [:],resolveLegacyPage:@escaping @Sendable (String)->NativeFeatureRoute? = {_ in nil},invalidateColdState:@escaping @MainActor @Sendable ([String])->Void = {_ in},makeSession:@escaping @MainActor @Sendable (FeatureAvailability)->any NativeFeatureSession) {
        self.manifest=manifest;self.pageContracts=pageContracts;self.ui=ui;self.menuShortcuts=menuShortcuts;self.resolveLegacyPage=resolveLegacyPage;self.invalidateColdState=invalidateColdState;self.makeSession=makeSession
    }
}

extension NativeFeatureSession {
    package func ui(_ surface:NativeUISurface,navigation:NativeNavigation)->AnyView?{nil}
    package func invalidateAfterRestore(_ paths:[String]) {}
    package func start() {}
    package func shutdown() {}
    package func preparePresentation(_ route:NativeFeatureRoute,options:[String:NativeContextValue]) {}
    package func prepareReview(_ route:NativeFeatureRoute,arguments:[String]) {}
    package func snapshotReady(_ route:NativeFeatureRoute,arguments:[String],started:Date)->Bool {status.snapshotReady}
    package func activate(_ entry:NativeUIEntryRef,navigation:NativeNavigation)->Bool {false}
}
