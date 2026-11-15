import Foundation
import SystemServicesAPI
import ThermoKit

/// Composition conveniences stay out of the presentation model's service contracts.
extension Monitor {
    convenience init(services:AppSystemServices,startMonitoring:Bool = true,samplingAllowed:@escaping @Sendable ()->Bool) {
        self.init(telemetry:services.telemetry,administration:services.helper,fanFactory:services.helper,
                  startMonitoring:startMonitoring,samplingAllowed:samplingAllowed)
    }
    convenience init(startMonitoring:Bool = true,helperInteraction:Bool = true,helper:HelperClient = .init(),
                     arguments:[String] = CommandLine.arguments,samplingAllowed:@escaping @Sendable ()->Bool = {true}) {
        self.init(services:AppSystemServices(helper:helper,helperInteraction:helperInteraction,arguments:arguments,samplingAllowed:samplingAllowed),
                  startMonitoring:startMonitoring,samplingAllowed:samplingAllowed)
    }
    nonisolated static func requestNotificationPermission(){Task{@MainActor in NotificationAccess.shared.request()}}
}
