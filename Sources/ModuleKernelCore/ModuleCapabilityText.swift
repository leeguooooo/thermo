import ModuleKit
import ThermoL10n

package enum ModuleCapabilityText {
    package static func title(_ kind:Capability.Kind)->String {
        switch kind {
        case .sensorsRead:return tr("Read sensors")
        case .processesRead:return tr("Read the process list")
        case .processesEnd:return tr("End processes")
        case .screenCapture:return tr("Capture the screen")
        case .accessibilityRead:return tr("Read accessibility information")
        case .filesRead:return tr("Read files")
        case .filesDelete:return tr("Remove files")
        case .networkConnect:return tr("Connect to network hosts")
        case .notificationsPost:return tr("Post notifications")
        case .fansControl:return tr("Control fans")
        }
    }
}
