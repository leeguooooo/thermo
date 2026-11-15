import SwiftUI

/// A panel: what cards and rows sit on. One flat surface with a hairline; no shadow.
package struct GlassPanel: ViewModifier {
    package init(radius:CGFloat = Theme.radius,highlighted:Bool = false) {self.radius=radius;self.highlighted=highlighted}
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var radius: CGFloat = Theme.radius
    var highlighted = false

    private var panelFill: Color {
        if reduceTransparency || contrast == .increased {
            return highlighted ? Color(red: 0.14, green: 0.15, blue: 0.17) : Color(red: 0.11, green: 0.12, blue: 0.14)
        }
        return highlighted ? Theme.surfaceRaised : Theme.surface
    }

    package func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(panelFill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(contrast == .increased ? Color.white.opacity(0.6) : highlighted ? Theme.border.opacity(1.6) : Theme.hairline,
                              lineWidth: contrast == .increased ? 2 : 1))
    }
}

extension View {
    package func glass(radius: CGFloat = Theme.radius, highlighted: Bool = false) -> some View {
        modifier(GlassPanel(radius: radius, highlighted: highlighted))
    }
}

/// Buttons in the window. `prominent` fills with the color, for the one thing a page asks you to do;
/// the rest are quiet grey.
package struct PillButtonStyle: ButtonStyle {
    package init(prominent:Bool = false,color:Color = Theme.accent) {self.prominent=prominent;self.color=color}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    var prominent = false
    var color: Color = Theme.accent

    package func makeBody(configuration: Configuration) -> some View {
        let small = controlSize == .small || controlSize == .mini
        return PillBody(configuration: configuration, prominent: prominent, color: color, small: small,
                        enabled: isEnabled, reduceMotion: reduceMotion)
    }

    private struct PillBody: View {
        let configuration: Configuration
        let prominent: Bool
        let color: Color
        let small: Bool
        let enabled: Bool
        let reduceMotion: Bool
        @State private var hover = false

        var fill: Color {
            if prominent { return color.opacity(configuration.isPressed ? 0.75 : hover ? 1 : 0.88) }
            return Color.white.opacity(configuration.isPressed ? 0.15 : hover ? 0.11 : 0.075)
        }

        var body: some View {
            configuration.label
                .font(.system(size: small ? 11.5 : 12.5, weight: prominent ? .semibold : .medium))
                .foregroundStyle(prominent ? Color.white : Theme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, small ? 9 : 12).frame(minHeight: small ? 22 : 28)
                .background(RoundedRectangle(cornerRadius: small ? 6 : 7, style: .continuous).fill(fill))
                .overlay(RoundedRectangle(cornerRadius: small ? 6 : 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(prominent ? 0.16 : 0.08)))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { hover = enabled && $0 }
                .animation(reduceMotion ? nil : Theme.quick, value: hover)
                .animation(reduceMotion ? nil : Theme.quick, value: configuration.isPressed)
        }
    }
}

