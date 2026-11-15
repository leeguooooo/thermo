import Foundation
import SwiftUI

package func tempText(_ c: Double?, fahrenheit: Bool) -> String {
    guard let c else { return "—" }
    return fahrenheit ? String(format: "%.0f°F", c * 9 / 5 + 32) : String(format: "%.0f°C", c)
}

package func heatColor(_ c: Double?) -> Color {
    guard let c else { return Theme.textTertiary }
    return c >= 85 ? Theme.danger : c >= 65 ? Theme.caution : Theme.good
}
