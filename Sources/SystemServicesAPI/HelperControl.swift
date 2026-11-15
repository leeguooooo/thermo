import Combine
import Foundation
import ThermoKit

package enum HelperState:Sendable,Equatable {case unknown,notInstalled,needsApproval,notRunning,outdated,running}
/// Observed helper state is owned by the core; requested edits are separate feature intent.
package struct HelperReading:Sendable {
    package var phase:HelperState = .unknown
    package var policies:[Int:FanPolicy]=[:]
    package var policiesAvailable=false
    package var fanControl:FanControlState?
    package var applyingPolicies=false,installing=false,uninstalling=false
    package var pendingPolicies:[Int:FanPolicy]=[:]
    package var lidAwake:LidAwakeState?
    package var lidAwakePending=false,lidAwakeBusy=false,settingUp=false
    package var setupStarted:Date?
    package var usesSMAppService=false
    package var error:String?
    package var busy:Bool{applyingPolicies || installing || uninstalling}
    package var canRetirePerformance:Bool{!busy && !settingUp && pendingPolicies.isEmpty}
    package init(){}
}
@MainActor package protocol FanPolicyAccess:AnyObject {
    var latest:HelperReading{get}
    var readings:AnyPublisher<HelperReading,Never>{get}
    /// Requests setup or a policy write. Completion and observed outcome are published separately.
    func request(_ policy:FanPolicy,fans:[Int])
    func refreshObservation()
    func beginRetiring()
    func finishRetiring() async
}
@MainActor package protocol FanPolicyAccessFactory:AnyObject {
    func bind(available:@escaping @MainActor ()->Bool)->any FanPolicyAccess
}
/// App-wide maintenance/lid/recovery stays usable independently of optional performance UI.
@MainActor package protocol HelperAdministration:AnyObject {
    var latest:HelperReading{get}
    var readings:AnyPublisher<HelperReading,Never>{get}
    func dismissError()
    func refresh()
    func install()
    func installWithPassword()
    func uninstall(finished:@escaping @MainActor ()->Void)
    func stopSetup()
    func setLidAwake(_ on:Bool)
    func openLoginItemsSettings()
    func restoreAutomaticFans(_ fans:[Int])
}
