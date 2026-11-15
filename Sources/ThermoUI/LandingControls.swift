import SwiftUI
import ThermoL10n

package struct ActionButtonStyle: ViewModifier {
    package init(prominent:Bool){self.prominent=prominent}

    let prominent: Bool
    package func body(content: Content) -> some View {
        if prominent { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
    }
}

package struct WindowBackdrop: View {
    package init(glow:Bool = true,tint:Color = Theme.accent){self.glow=glow;self.tint=tint}

    var glow = true
    var tint: Color = Theme.accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    package var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.canvas, Theme.canvasDeep], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [tint.opacity(glow ? 0.16 : 0.07), .clear],
                           center: UnitPoint(x: 0.62, y: -0.08), startRadius: 0, endRadius: 560)
                .animation(Theme.gentle.unlessReduced(reduceMotion), value: glow)
        }
        .ignoresSafeArea()
    }
}

package struct IconTile: View {
    package init(symbol:String,color:Color,size:CGFloat = 44){self.symbol=symbol;self.color=color;self.size=size}

    let symbol: String
    let color: Color
    var size: CGFloat = 44

    package var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(color.opacity(0.16))
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(color.opacity(0.22), lineWidth: 1)
            Image(systemName: symbol).font(.system(size: size * 0.44, weight: .semibold)).foregroundStyle(color)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

package struct PressableStyle: ButtonStyle {
    package init(){}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    package func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

package struct BigRoundButton: View {
    package init(title:String,color:Color = Theme.accent,busy:Bool = false,action:@escaping ()->Void){self.title=title;self.color=color;self.busy=busy;self.action=action}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    var color: Color = Theme.accent
    var busy = false
    let action: () -> Void
    @State private var hover = false

    package var body: some View {
        Button(action: action) {
            ZStack {
                if busy {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                }
            }
            .padding(.horizontal, 28).frame(minWidth: 148).frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(hover ? 1 : 0.9)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.18)))
            .shadow(color: color.opacity(hover ? 0.45 : 0.25), radius: hover ? 14 : 8, y: 4)
            .animation(Theme.quick.unlessReduced(reduceMotion), value: hover)
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
        .disabled(busy)
    }
}

package struct HeroStatus: View {
    package init(symbol:String,color:Color,title:String,subtitle:String,progress:Double? = nil,spinning:Bool = false){self.symbol=symbol;self.color=color;self.title=title;self.subtitle=subtitle;self.progress=progress;self.spinning=spinning}

    let symbol: String
    let color: Color
    let title: String
    let subtitle: String
    /// 0…1 while scanning or fixing; nil when idle.
    var progress: Double? = nil
    var spinning = false
    @State private var turning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    package var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(RadialGradient(colors: [color.opacity(0.22), .clear], center: .center, startRadius: 20, endRadius: 90))
                    .frame(width: 180, height: 180)
                Circle().stroke(Color.white.opacity(0.07), lineWidth: 5).frame(width: 128, height: 128)
                if let progress {
                    Circle().trim(from: 0, to: max(0.02, progress))
                        .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90)).frame(width: 128, height: 128)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: progress)
                } else if spinning {
                    Circle().trim(from: 0, to: 0.22)
                        .stroke(AngularGradient(colors: [color.opacity(0), color], center: .center),
                                style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .frame(width: 128, height: 128)
                        .rotationEffect(.degrees(turning ? 360 : 0))
                        .animation(reduceMotion ? nil : .linear(duration: 1.1).repeatForever(autoreverses: false), value: turning)
                } else {
                    Circle().stroke(color.opacity(0.85), lineWidth: 5).frame(width: 128, height: 128)
                }
                Image(systemName: symbol).font(.system(size: 40, weight: .semibold)).foregroundStyle(color)
                    .contentTransition(.opacity)
            }
            // Animate only the ring: a repeatForever started with withAnimation in onAppear would also
            // animate the first layout of the whole window, and everything would drift forever.
            .onAppear { DispatchQueue.main.async { turning = true } }
            .animation(Theme.standard.unlessReduced(reduceMotion), value: symbol)
            Text(title).font(Theme.pageTitle).foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center).contentTransition(.numericText())
            Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                .frame(maxWidth: 460).fixedSize(horizontal: false, vertical: true)
        }
    }
}

package struct CategoryCard: View {
    package init(symbol:String,color:Color,title:String,status:String,statusColor:Color,count:Int? = nil,action:@escaping ()->Void){self.symbol=symbol;self.color=color;self.title=title;self.status=status;self.statusColor=statusColor;self.count=count;self.action=action}

    let symbol: String
    let color: Color
    let title: String
    let status: String
    let statusColor: Color
    /// The big figure on the card ("4"); nil shows a check.
    var count: Int? = nil
    let action: () -> Void
    @State private var hover = false

    package var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    IconTile(symbol: symbol, color: color, size: 32)
                    Spacer()
                    if let count, count > 0 {
                        Text("\(count)").font(Theme.figure(.metric)).foregroundStyle(statusColor)
                            .contentTransition(.numericText())
                    } else {
                        Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.good)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text(status).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .padding(14)
            .glass(highlighted: hover)
            .overlay(alignment: .topTrailing) {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textTertiary)
                    .padding(14).padding(.top, 58).opacity(hover ? 1 : 0)
            }
            .animation(Theme.quick, value: hover)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
    }
}

package struct RingGauge: View {
    package init(value:Double?,text:String,caption:String? = nil,size:CGFloat = 112,colors:[Color] = [.green,.yellow,.orange,.red]){self.value=value;self.text=text;self.caption=caption;self.size=size;self.colors=colors}

    /// 0…1.
    let value: Double?
    let text: String
    var caption: String? = nil
    var size: CGFloat = 112
    var colors: [Color] = [.green, .yellow, .orange, .red]

    package var normalizedValue: Double? {
        guard let value, value.isFinite else { return nil }
        return min(1, max(0, value))
    }
    package var displayText: String { normalizedValue == nil ? "—" : text }

    package var color: Color {
        guard !colors.isEmpty, let normalized = normalizedValue else { return .secondary }
        let i = min(colors.count - 1, Int(normalized * Double(colors.count)))
        return colors[i]
    }

    package var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: size * 0.085, lineCap: .round))
                .rotationEffect(.degrees(135)).mask(Circle().trim(from: 0, to: 0.75).stroke(lineWidth: size * 0.1).rotationEffect(.degrees(135)))
            if let normalized = normalizedValue, !colors.isEmpty {
                Circle().trim(from: 0, to: 0.75 * normalized)
                    .stroke(AngularGradient(colors: colors, center: .center, startAngle: .degrees(0), endAngle: .degrees(270)),
                            style: StrokeStyle(lineWidth: size * 0.085, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .shadow(color: color.opacity(0.35), radius: 4)
            }
            VStack(spacing: 0) {
                Text(displayText).font(Theme.figure(points: size * 0.21)).contentTransition(.numericText())
                    .foregroundStyle(Theme.textPrimary).lineLimit(1).minimumScaleFactor(0.5)
                if let caption {
                    Text(caption).font(.system(size: size * 0.095, weight: .medium)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
            }
            .padding(.horizontal, size * 0.16)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption ?? "")
        .accessibilityValue(normalizedValue == nil ? tr("No reading available") : text)
    }
}
