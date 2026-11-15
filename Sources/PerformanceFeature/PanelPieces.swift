import ThermoUI
import SwiftUI

struct PanelCard<Content: View>: View {
    let title: String
    let symbol: String
    var tint: Color = Theme.textTertiary
    var badge: String? = nil
    var badgeTint: Color = Theme.textSecondary
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint).accessibilityHidden(true)
                // One line each: in English "Free space · 995 GB total" is a hair too wide for a half-width card.
                Text(title).font(Theme.label).foregroundStyle(Theme.textTertiary).lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                if let badge {
                    Text(badge).font(Theme.label.monospacedDigit()).foregroundStyle(badgeTint)
                        .lineLimit(1).minimumScaleFactor(0.85)
                        .contentTransition(.numericText())
                }
            }
            content()
        }
        .padding(Theme.Space.m - 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radius - 1, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius - 1, style: .continuous).strokeBorder(Theme.hairline))
    }
}

struct BigValue: View {
    let value: String
    var unit: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value).font(Theme.figure(.metric)).foregroundStyle(Theme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            if let unit { Text(unit).font(Theme.label).foregroundStyle(Theme.textTertiary) }
        }
    }
}

/// A light line with a soft fill; draws nothing until there are two points.
struct Sparkline: View {
    let values: [Double]
    var top: Double? = nil
    var color: Color = Theme.accent

    var body: some View {
        GeometryReader { g in
            let maxValue = max(top ?? 0, values.max() ?? 0, 1e-9)
            // The newest sample sits at the right edge; a short history grows in from the right.
            let offset = PanelModel.length - values.count
            let points = values.enumerated().map { i, v in
                CGPoint(x: g.size.width * CGFloat(i + offset) / CGFloat(PanelModel.length - 1),
                        y: g.size.height * (1 - CGFloat(min(v, maxValue) / maxValue)))
            }
            if points.count > 1 {
                Path { p in p.addLines(points) }.stroke(color, style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
                Path { p in
                    p.move(to: CGPoint(x: points[0].x, y: g.size.height)); p.addLines(points)
                    p.addLine(to: CGPoint(x: points.last!.x, y: g.size.height)); p.closeSubpath()
                }.fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
            } else {
                Rectangle().fill(Theme.hairline).frame(height: 1).frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(height: 26)
        .accessibilityHidden(true)
    }
}

struct UsageBar: View {
    let fraction: Double
    var color: Color = Theme.accent
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.07))
                Capsule().fill(color).frame(width: g.size.width * CGFloat(min(1, max(0, fraction.isFinite ? fraction : 0))))
            }
        }
        .frame(height: 4).padding(.vertical, 11)
        .accessibilityHidden(true)
    }
}

/// A plain-SwiftUI button: it also draws in the `--render-preview` image, unlike AppKit controls.
