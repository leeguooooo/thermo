import Foundation
import SwiftUI
import ThermoL10n

package struct PanelButton: View {
    let title: String
    var symbol: String? = nil
    var prominent = false
    var on = false
    let action: () -> Void
    package init(title: String, symbol: String? = nil, prominent: Bool = false, on: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.prominent = prominent; self.on = on; self.action = action
    }
    package var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(Theme.caption.weight(on || prominent ? .semibold : .medium)).lineLimit(1)
            }
            // A crowded row squeezes other things first; the label never breaks onto two lines.
            .fixedSize()
            .padding(.horizontal, 10).frame(minHeight: 24)
            .foregroundStyle(on || prominent ? Color.white : Theme.textPrimary)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(prominent ? Theme.accent : on ? Theme.accent.opacity(0.8) : Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

package enum PanelFormat {
    package static func rate(_ bytesPerSecond: Double?) -> (String, String) {
        guard let b = bytesPerSecond, b.isFinite else { return ("—", "") }
        if b >= 1_000_000 { return (String(format: b >= 10_000_000 ? "%.0f" : "%.1f", b / 1_000_000), "MB/s") }
        return (String(format: "%.0f", b / 1000), "KB/s")
    }
    /// Memory in GiB, the way macOS labels it ("16 GB" for 16 GiB).
    package static func gb(_ bytes: UInt64) -> String {
        let g = Double(bytes) / 1_073_741_824
        return g.rounded() == g || g >= 100 ? String(format: "%.0f", g) : String(format: "%.1f", g)
    }
    package static func duration(minutes: Int) -> String {
        minutes >= 60 ? tr("%1$@ h %2$@ min", String(minutes / 60), String(minutes % 60)) : tr("%1$@ min", String(minutes))
    }
    package static func uptime(_ seconds: TimeInterval) -> String {
        let days = Int(seconds / 86_400)
        return days >= 1 ? tr("up %1$@ d", String(days)) : tr("up %1$@ h", String(max(1, Int(seconds / 3600))))
    }
}
