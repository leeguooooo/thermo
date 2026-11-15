import Foundation
import ThermoL10n

extension Date {
    /// `formatted(date:time:)` in the UI language's locale rather than the Mac's region.
    package func text(date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle) -> String {
        formatted(Date.FormatStyle(date: date, time: time, locale: L10n.locale))
    }
}
