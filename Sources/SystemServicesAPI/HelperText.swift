import Foundation
import ThermoKit
import ThermoL10n

package enum FanPolicyText {
    package static func error(_ error:String)->String {
        if error.contains("no automatic-control readback key") || error.contains("no manual-control readback key") {
            return tr("Fan control could not be verified on this Mac. Open fan settings for details.")
        }
        return error
    }
    package static func label(_ policy: FanPolicy) -> String {
        switch policy {
        case .auto: return tr("Auto")
        case .fixed(let r): return r == .infinity ? tr("Max") : tr("%1$@ rpm", String(format: "%.0f", r))
        case .curve(let curve): return tr("Curve") + " · " + curve.pointsText + " (" + curve.sensor.rawValue.uppercased() + ")"
        }
    }
}

extension FanReading {
    /// The SMC reports "Fan" / "Fan 2" in English when the hardware has no name of its own.
    package var displayName: String {
        if name == "Fan" { return tr("Fan") }
        if name.hasPrefix("Fan "), let n = Int(name.dropFirst(4)) { return tr("Fan %1$@", String(n)) }
        return name
    }
}


package enum LidAwakeText {
    package static func autoOff(_ off: LidAwakeState.AutoOff) -> String {
        switch off.reason {
        case "thermal": return tr("Turned off because the Mac got too hot (%1$@).", off.detail)
        case "battery": return tr("Turned off because the battery is low (%1$@).", off.detail)
        case "noReading": return tr("Turned off because the temperature could not be read.")
        default: return off.detail
        }
    }
}

