import CleanKit
import Foundation
import SwiftUI
import ThermoL10n
import ThermoUI

/// Check-up and memory advice send the same kind of facts and retain the existing shared consent.
@MainActor package final class CheckupConsent {
    private let defaults:UserDefaults
    package init(defaults:UserDefaults = .standard){self.defaults=defaults}
    package var allowed:Bool {
        get{defaults.bool(forKey:"localAI.checkupConsented")}
        set{defaults.set(newValue,forKey:"localAI.checkupConsented")}
    }
}
package enum AISafetyPresentation {
    package static func label(_ safety:CheckupFinding.Safety)->(String,Color) {
        switch safety {
        case .safe:return(tr("Safe to do"),Theme.good)
        case .interrupts:return(tr("Interrupts work"),Theme.caution)
        case .avoid:return(tr("Don't do it"),Theme.danger)
        }
    }
}
