import Foundation
import ThermoKit

extension SystemPresentation {
    convenience init(services:AppSystemServices){self.init(telemetry:services.telemetry,administration:services.helper)}
    convenience init(helperInteraction:Bool = true,helper:HelperClient = .init(),arguments:[String] = CommandLine.arguments){
        self.init(services:AppSystemServices(helper:helper,helperInteraction:helperInteraction,arguments:arguments,samplingAllowed:{false}))
    }
}
