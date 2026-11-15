import ModuleKit
import SwiftUI

package struct NativeFeatureRoute:Hashable,Sendable {
    package let module:String
    package let entry:String
    package init(_ module:String,_ entry:String) {self.module=module;self.entry=entry}
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
package struct NativeFeatureBusy:Error,CustomStringConvertible {
    package let description:String
    package init(_ reason:String){description=reason}
}
@MainActor package struct NativeFeatureDrain {
    package let finish:() async->Void
    package init(finish:@escaping () async->Void){self.finish=finish}
}
/// Native feature implementations own models; callers see only UI and lifecycle contributions.
@MainActor package protocol NativeFeatureSession:AnyObject {
    func page(entry:String)->AnyView?
    var status:NativeFeatureStatus {get}
    func retireVisibility()
    func quitBlocker()->NativeFeatureBlocker?
    func prepareStop()throws->NativeFeatureDrain
}
package struct NativeFeatureDefinition {
    package let manifest:ModuleManifest
    package let makeSession:@MainActor (FeatureAvailability)->any NativeFeatureSession
    package init(manifest:ModuleManifest,makeSession:@escaping @MainActor (FeatureAvailability)->any NativeFeatureSession) {
        self.manifest=manifest;self.makeSession=makeSession
    }
}
