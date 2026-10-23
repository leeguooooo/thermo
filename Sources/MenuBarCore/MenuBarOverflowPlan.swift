import Foundation

/// Geometry for a macOS 27 separator made of individually bounded status
/// items. A single oversized item is discarded by that menu bar model.
public struct MenuBarOverflowPlan: Equatable, Sendable {
    public struct Display: Equatable, Sendable {
        public let width: Double
        public let statusWidth: Double
        public init(width: Double, statusWidth: Double? = nil) {
            self.width = width
            self.statusWidth = statusWidth ?? width
        }
    }
    public static let maximumFillers = 6
    public let itemLength: Double
    public let fillerCount: Int
    public var totalLength: Double { itemLength * Double(fillerCount + 1) }

    public static func native27(displays: [Display]) -> Self? {
        guard !displays.isEmpty, displays.allSatisfy({
            $0.width.isFinite && $0.statusWidth.isFinite && $0.width > 0 &&
                $0.statusWidth > 0 && $0.statusWidth <= $0.width
        }) else { return nil }
        let thresholds = displays.map { display in
            display.statusWidth < display.width ? display.statusWidth * 0.75 : display.width / 2
        }
        guard let lowest = thresholds.min(), let widest = displays.map(\.statusWidth).max() else { return nil }
        let length = floor(lowest - 64)
        guard length > 0, length < lowest else { return nil }
        let count = ceil(widest / length)
        // Refuse an unsupported display combination instead of reporting a
        // collapse whose spacers cannot cover the available status area.
        guard count.isFinite, count >= 1, count <= Double(maximumFillers + 1) else { return nil }
        return Self(itemLength: length, fillerCount: Int(count) - 1)
    }
}
