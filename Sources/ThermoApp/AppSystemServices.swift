import Foundation
import ModuleKit
import SystemServicesAPI
import ThermoKernel
import ThermoKit

/// Composition: the normal application shares one pair; isolated fixtures own their own pair.
@MainActor final class AppSystemServices {
    let telemetry:CoreTelemetry
    lazy var helper=makeHelper()
    private let makeHelper:()->CoreHelperAdministration
    init(defaults:UserDefaults = .standard,helper:HelperClient = .init(),helperInteraction:Bool = true,
         arguments:[String] = CommandLine.arguments,samplingAllowed:@escaping @Sendable ()->Bool) {
        let telemetry=CoreTelemetry(defaults:defaults,samplingAllowed:samplingAllowed)
        self.telemetry=telemetry
        makeHelper={CoreHelperAdministration(helper:helper,automaticInteractionAllowed:helperInteraction && !AppLaunchMode.suppressesAutomaticControl(arguments:arguments),
            beginMaintenance:{AppExitGuard.beginHelperMaintenance()},endMaintenance:{AppExitGuard.endHelperMaintenance($0)},
            fans:{[weak telemetry] in telemetry?.latest.sampledFans ?? []},refreshTelemetry:{[weak telemetry] in telemetry?.refreshCurrent()})}
    }
}

enum AppLaunchMode {
    static func suppressesAutomaticControl(arguments:[String])->Bool{arguments.contains{["--offscreen","--snapshot","--render-preview","--verify-lifecycle","--ui-review"].contains($0)}}
}
