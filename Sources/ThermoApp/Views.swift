import CleanKit
import Charts
import SwiftUI
import ThermoKit
import ThermoL10n

// MARK: - Formatting

func tempText(_ c: Double?, fahrenheit: Bool) -> String {
    guard let c else { return "—" }
    return fahrenheit ? String(format: "%.0f°F", c * 9 / 5 + 32) : String(format: "%.0f°C", c)
}

/// A sensor group's name for people ("存储" rather than "Storage").
func groupName(_ g: SensorGroup) -> String {
    switch g {
    case .cpu: return "CPU"
    case .gpu: return "GPU"
    case .memory: return tr("Memory")
    case .storage: return tr("Storage")
    case .battery: return tr("Battery")
    case .ambient: return tr("Ambient")
    case .board: return tr("Board")
    case .other: return tr("Other")
    }
}

func heatColor(_ c: Double?) -> Color {
    guard let c else { return Theme.textTertiary }
    return c >= 85 ? Theme.danger : c >= 65 ? Theme.caution : Theme.good
}

/// Lightweight level bar (cheaper than ProgressView and tinted per value).
struct Bar: View {
    let value: Double
    var color: Color = Theme.accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.07))
                Capsule().fill(color).frame(width: g.size.width * min(1, max(0, value.isFinite ? value : 0)))
            }
        }
        .frame(height: 4)
        .animation(Theme.gentle.unlessReduced(reduceMotion), value: value)
    }
}

/// The menu bar panel lays feature rows out as small tiles; Settings shows them as full rows.
private struct FeatureRowCompactKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var featureRowCompact: Bool {
        get { self[FeatureRowCompactKey.self] }
        set { self[FeatureRowCompactKey.self] = newValue }
    }
}

/// A feature that opens its own panel (Clean Screen, Keep awake…): symbol, name, a status on the
/// right and a chevron, like a row in System Settings. A green dot marks one that is running.
struct FeatureRow: View {
    let title: String
    let symbol: String
    var status: String? = nil
    var statusColor: Color = Theme.textTertiary
    var active = false
    /// A problem to show under the row.
    var note: String? = nil
    @Environment(\.featureRowCompact) private var compact

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: compact ? Theme.Space.s : Theme.Space.m) {
                Image(systemName: symbol).font(.system(size: compact ? 11 : 13, weight: .medium))
                    .foregroundStyle(active ? Theme.good : Theme.textSecondary).frame(width: compact ? 14 : 18)
                    .accessibilityHidden(true)
                Text(title).font(compact ? Theme.secondary : Theme.body).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer(minLength: Theme.Space.xs)
                if active { Circle().fill(Theme.good).frame(width: 6, height: 6).accessibilityLabel(tr("On")) }
                if let status { Text(status).font(Theme.caption).foregroundStyle(statusColor).lineLimit(1) }
                if !compact {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textTertiary)
                        .accessibilityHidden(true)
                }
            }
            if let note {
                Text(note).font(Theme.caption).foregroundStyle(Theme.caution).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, compact ? 22 : 30)
            }
        }
        .padding(.horizontal, compact ? Theme.Space.s + 2 : Theme.Space.l)
        .padding(.vertical, compact ? Theme.Space.s : Theme.Space.m)
        .frame(maxWidth: .infinity, minHeight: compact ? 30 : 44, alignment: .leading)
        .contentShape(Rectangle())
        .hoverHighlight(radius: compact ? Theme.radiusSmall : 0)
    }
}

// MARK: - Root

/// The menu bar panel: the live numbers at a glance, why the Mac is slow, a quick fan switch, and
/// the way into the main window, where everything else lives.
struct PopoverView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject private var panel = PanelModel.shared
    @ObservedObject private var pulse = SystemPulse.shared
    @AppStorage(Settings.fahrenheit) private var fahrenheit = false
    @AppStorage(L10n.defaultsKey) private var language = "system"
    @AppStorage(MenuBarPreferences.leftKey) private var menuLeftClick = "panel"
    @AppStorage(MenuBarPreferences.rightKey) private var menuRightClick = "menu"

    var body: some View {
        let _ = L10n.apply(preference: language)
        content.id(language)  // rebuild every string in the new language
    }

    var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            if renderingPreview {
                mainSections
            } else {
                ScrollView(.vertical) {
                    mainSections
                }
                // Live samples and errors scroll inside a stable viewport that shrinks on short screens.
                .frame(minHeight: 120, idealHeight: 640, maxHeight: 640)
                // Features that open their own panel, as small tiles two by two.
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Space.s), GridItem(.flexible(), spacing: Theme.Space.s)],
                          spacing: Theme.Space.s) {
                    Group {
                        CleanScreenButton(); AWDLButton(); IdleAwakeButton()
                        if monitor.snapshot?.battery != nil { BatteryCareButton() }
                    }
                    .background(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).strokeBorder(Theme.hairline))
                }
                .environment(\.featureRowCompact, true)
            }
            footer
        }
        .padding(Theme.Space.m)
        .frame(width: 372)
        .background(LinearGradient(colors: [Theme.canvas, Theme.canvasDeep], startPoint: .top, endPoint: .bottom))
        .preferredColorScheme(.dark)
        .environment(\.windowSamplingActive, monitor.popoverOpen)
    }

    private var mainSections: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if monitor.iconHidden {
                // The menu bar icon is behind the notch; say how to get it back.
                Label(tr("The menu bar icon is hidden behind the notch. Hold ⌘ and drag other icons out of the menu bar to make room, or open Thermo from the Dock."),
                      systemImage: "eye.slash")
                    .font(Theme.caption).foregroundStyle(Theme.caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .onTapGesture { monitor.iconHidden = false }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                cpuCard; gpuCard; memoryCard; diskCard; networkCard; fanCard
            }
            if let b = monitor.snapshot?.battery { batteryCard(b) }
            programs
            if monitor.snapshot?.battery != nil || renderingPreview {
                LidAwakeSwitch(monitor: monitor)
                    .padding(Theme.Space.m - 2)
                    .background(RoundedRectangle(cornerRadius: Theme.radius - 1, style: .continuous).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius - 1, style: .continuous).strokeBorder(Theme.hairline))
            }
            if let err = monitor.lastError {
                Text(FanControlPresentation.errorText(err)).help(err).font(Theme.caption).foregroundStyle(Theme.danger).lineLimit(3)
                    .onTapGesture { monitor.lastError = nil }
            }
        }
    }

    // MARK: Header: how hot, why, and who

    var header: some View {
        let hot = monitor.snapshot?.maximumKnownTemperature
        let current = pulse.current
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(tempText(hot, fahrenheit: fahrenheit))
                    .font(Theme.figure(.hero))
                    .foregroundStyle(heatColor(hot))
                    .contentTransition(.numericText())
                    .animation(Theme.standard, value: hot)
                Text(current == nil ? tr("Checking…") : verdictWord)
                    .font(Theme.rowTitle.weight(.semibold)).foregroundStyle(current == nil ? Theme.textTertiary : verdictColor)
                Spacer()
                if let w = monitor.snapshot?.systemPower {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(String(format: "%.1f W", w)).font(Theme.figure(.row)).foregroundStyle(Theme.textPrimary)
                            .contentTransition(.numericText())
                        Text(tr("System")).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            Text(current.flatMap { OverviewPage.sourceText($0) ?? $0.culpritText } ?? (current == nil ? tr("Checking…") : ""))
                .font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .topLeading)
            HStack(spacing: 5) {
                ForEach([panel.chip, PanelFormat.gb(panel.memoryTotal) + " GB", panel.macOS] + (PanelModel.uptime.map { [PanelFormat.uptime($0)] } ?? []), id: \.self) { fact in
                    Text(fact).font(Theme.label).foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(0.06)))
                }
            }
        }
    }

    var verdictColor: Color {
        if pulse.severity == .green { return Theme.good }
        if pulse.severity == .red { return Theme.danger }
        return Theme.caution
    }

    /// The verdict in two or three words, for the header.
    var verdictWord: String {
        switch pulse.current?.verdict {
        case .hot: return tr("Too hot")
        case .disk: return tr("Disk full")
        case .overloaded: return tr("Overloaded")
        case .memory: return tr("Memory tight")
        case .busy: return tr("Busy")
        default: return tr("All good")
        }
    }

    // MARK: Cards

    var cpuCard: some View {
        let s = monitor.snapshot
        let busy = pulse.current?.busy
        return PanelCard(title: "CPU", symbol: "cpu", badge: s?.cpu.map { tempText($0, fahrenheit: fahrenheit) },
                         badgeTint: heatColor(s?.cpu)) {
            BigValue(value: panel.currentCPU.map { String(format: "%.0f", $0) } ?? "—", unit: "%")
            Sparkline(values: panel.cpu, top: 100)
            Text([busy.map { tr("load %1$@× per core", String(format: "%.1f", $0)) }, s?.cpuPower.map { String(format: "%.1f W", $0) }]
                .compactMap { $0 }.joined(separator: " · "))
                .font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
        }
    }

    var gpuCard: some View {
        let s = monitor.snapshot
        return PanelCard(title: "GPU", symbol: "square.stack.3d.up", badge: s?.gpu.map { tempText($0, fahrenheit: fahrenheit) },
                         badgeTint: heatColor(s?.gpu)) {
            BigValue(value: panel.currentGPU.map { String(format: "%.0f", $0) } ?? "—", unit: panel.currentGPU == nil ? nil : "%")
            Sparkline(values: panel.gpu, top: 100)
            Text(panel.currentGPU == nil ? tr("not reported") : (panel.currentGPU ?? 0) >= 50 ? tr("busy") : tr("light"))
                .font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
        }
    }

    var memoryCard: some View {
        let m = panel.memoryStats
        let pressure = pulse.current?.memory ?? .unknown
        return PanelCard(title: tr("Memory"), symbol: "memorychip", badge: MachinePulse.memoryName(pressure),
                         badgeTint: pressure == .critical ? Theme.danger : pressure == .warning ? Theme.caution : Theme.textSecondary) {
            BigValue(value: m.map { String(format: "%.0f", Double($0.usedBytes) / Double(max(1, $0.totalBytes)) * 100) } ?? "—", unit: "%")
            Sparkline(values: panel.memory, top: 100)
            Text([m.map { PanelFormat.gb($0.usedBytes) + " / " + PanelFormat.gb($0.totalBytes) + " GB" },
                  pulse.current.flatMap { $0.swapUsedMB > 0 ? tr("swap %1$@", MemoryFormat.string(mebibytes: $0.swapUsedMB)) : nil }]
                .compactMap { $0 }.joined(separator: " · "))
                .font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
        }
    }

    var diskCard: some View {
        let d = panel.diskStats
        let used = d.map { 1 - Double($0.freeBytes) / Double(max(1, $0.totalBytes)) } ?? 0
        return PanelCard(title: tr("Free space"), symbol: "internaldrive",
                         badge: d.map { ByteFormat.string($0.totalBytes) }) {
            BigValue(value: d.map { ByteFormat.string($0.freeBytes) } ?? "—")
            UsageBar(fraction: used, color: used > 0.9 ? Theme.caution : Theme.accent)
            Text(d.map { tr("%1$@ used · %2$@", ByteFormat.string($0.totalBytes - $0.freeBytes), String(format: "%.0f%%", used * 100)) } ?? "")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
        }
    }

    var networkCard: some View {
        let (down, unit) = PanelFormat.rate(panel.currentDownload)
        let (up, upUnit) = PanelFormat.rate(panel.upload)
        return PanelCard(title: tr("Network"), symbol: "network") {
            BigValue(value: down, unit: unit)
            Sparkline(values: panel.download)
            Text(tr("upload %1$@", up + " " + upUnit)).font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
        }
    }

    var fanCard: some View {
        let fans = monitor.sampledFans ?? []
        let top = fans.filter { $0.rpm != nil }.max { $0.rpm! < $1.rpm! }
        return PanelCard(title: tr("Fans"), symbol: "fan",
                         badge: top?.load.map { String(format: "%.0f%%", $0 * 100) }) {
            BigValue(value: top.map { (fans.contains { $0.rpm == nil } ? "≥ " : "") + FanControlPresentation.rpm($0.rpm) } ?? "—", unit: top == nil ? nil : "RPM")
            if fans.isEmpty {
                Text(monitor.sampledFans == nil ? monitor.fanEmptyMessage : tr("No fans")).font(Theme.caption).foregroundStyle(Theme.textTertiary)
            } else if monitor.policiesAvailable {
                let policies = fans.map { FanControlPresentation.selectedPolicy(fan: $0.id, available: monitor.policiesAvailable, policies: monitor.policies, pending: monitor.pendingPolicies, state: monitor.fanControlState) }
                let allAuto = policies.allSatisfy { $0 == .auto }
                let allMax = zip(fans, policies).allSatisfy { fan, policy in
                    if case .fixed(let rpm)? = policy, let range=fan.validRange { return rpm.isInfinite || rpm >= range.max } else { return false }
                }
                Text(tr("Requested policy")).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                HStack(spacing: 4) {
                    PanelButton(title: tr("Auto"), on: allAuto) { monitor.setPolicy(.auto, fans: fans.map(\.id)) }
                    PanelButton(title: tr("Max"), on: allMax) { monitor.setPolicy(.fixed(rpm: .infinity), fans: fans.map(\.id)) }
                        .disabled(fans.contains { $0.validRange == nil })
                }
                .disabled(monitor.helperBusy).padding(.top, 4)
            } else {
                Text(tr(fans.contains { $0.manual == true } ? "manual" : fans.contains { $0.manual == nil } ? "unknown" : "auto"))
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                PanelButton(title: tr("Fan settings…")) { MainWindow.show(.fans) }
            }
        }
    }

    func batteryCard(_ b: BatteryInfo) -> some View {
        let power = b.power.map { abs($0) }
        let detail: String = {
            if b.charging { return tr("Charging") + (power.map { String(format: " · %.1f W", $0) } ?? "") }
            if b.externalPower { return tr("On power adapter") }
            return [power.map { tr("drawing %1$@", String(format: "%.1f W", $0)) },
                    panel.batteryMinutesLeft.map { tr("%1$@ left", PanelFormat.duration(minutes: $0)) }].compactMap { $0 }.joined(separator: " · ")
        }()
        return PanelCard(title: tr("Battery"), symbol: b.charging ? "battery.100.bolt" : "battery.75", tint: (b.percent ?? 100) < 20 ? Theme.danger : Theme.textTertiary,
                         badge: b.health.map { tr("health %1$@%%", String(format: "%.0f", $0 * 100)) }) {
            HStack(alignment: .firstTextBaseline) {
                BigValue(value: b.percent.map { String(format: "%.0f", $0) } ?? "—", unit: "%")
                Spacer()
                Text(detail).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
        }
    }

    /// The busiest programs, each with the project and agent behind it.
    var programs: some View {
        let hogs = Array((pulse.current?.hogs ?? []).sorted { $0.cpu > $1.cpu }.prefix(5))
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(tr("Busiest programs")).font(Theme.sectionTitle).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(tr("Memory")).frame(width: 64, alignment: .trailing)
                Text("CPU").frame(width: 46, alignment: .trailing)
            }
            .font(Theme.label).foregroundStyle(Theme.textTertiary).padding(.bottom, Theme.Space.xs)
            if hogs.isEmpty {
                if pulse.current == nil {
                    VStack(alignment: .leading, spacing: 6) { SkeletonBar(width: 160, height: 8); SkeletonBar(width: 120, height: 8) }
                        .padding(.vertical, 6)
                } else {
                    Text(tr("Nothing is busy.")).font(Theme.caption).foregroundStyle(Theme.textTertiary).padding(.vertical, 6)
                }
            }
            ForEach(hogs) { h in
                Button { MainWindow.show(.compute(false)) } label: {
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(h.name).font(Theme.secondary.weight(.medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                            if let origin = Self.origin(h) {
                                Text(origin).font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        Text(MemoryFormat.string(kibibytes: h.memoryKB)).font(Theme.caption.monospacedDigit())
                            .foregroundStyle(Theme.textSecondary).frame(width: 64, alignment: .trailing)
                        Text(String(format: "%.0f", h.cpu)).font(Theme.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(h.cpu >= 100 ? Theme.danger : h.cpu >= 50 ? Theme.caution : Theme.textPrimary)
                            .contentTransition(.numericText())
                            .frame(width: 46, alignment: .trailing)
                    }
                    .padding(.vertical, Theme.Space.xs).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Theme.Space.m - 2)
        .background(RoundedRectangle(cornerRadius: Theme.radius - 1, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius - 1, style: .continuous).strokeBorder(Theme.hairline))
    }

    /// "thermo · Claude Code": the working folder and a currently observed ancestor.
    static func origin(_ h: MachinePulse.Hog) -> String? {
        let folder = h.project.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty || $0 == "~" ? nil : $0 }
        let parts = [folder, h.owner].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Footer

    var footer: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                PanelButton(title: tr("Open Console"), symbol: "macwindow", prominent: true) { MainWindow.show(.overview) }
                Spacer(minLength: 0)
                shortcut("internaldrive", tr("Disk Cleanup"), .disk(.home))
                shortcut("stethoscope", tr("AI Agent Diagnostics"), .agents(.home))
                Button { TabQuickAction.request() } label: { Image(systemName: "archivebox").frame(width: 22) }
                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).help(tr("Save and close background tabs"))
                shortcut("clock.arrow.circlepath", tr("History"), .history)
                PanelButton(title: tr("Menu bar…")) { MainWindow.show(.settings) }
                    .accessibilityLabel(tr("Customize menu bar…"))
                    .help(tr("Choose metrics, layout and left/right click actions."))
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power").frame(width: 22) }
                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).help(tr("Quit Thermo"))
            }
            Text(tr("Left click: %1$@ · Right click: %2$@",
                    (MenuClickAction(rawValue: menuLeftClick) ?? .panel).label,
                    (MenuClickAction(rawValue: menuRightClick) ?? .menu).label))
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }

    func shortcut(_ symbol: String, _ title: String, _ page: MainPage) -> some View {
        Button { MainWindow.show(page) } label: { Image(systemName: symbol).frame(width: 22) }
            .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).help(title).accessibilityLabel(title)
    }
}

/// Auto or full speed in one click; anything finer is in the main window's Fans page.
struct QuickFanSwitch: View {
    @ObservedObject var monitor: Monitor
    let fan: FanReading

    /// These buttons select desired policies; register observations are separate.
    var current: FanPolicy? { FanControlPresentation.selectedPolicy(fan: fan.id, available: monitor.policiesAvailable, policies: monitor.policies, pending: monitor.pendingPolicies, state: monitor.fanControlState) }
    var isMax: Bool { if case .fixed(let r)? = current, let max = fan.max { return r.isInfinite || r >= max } else { return false } }
    var isCustom: Bool { current != nil && current != .auto && !isMax }

    var body: some View {
        HStack(spacing: 4) {
            Text(tr("Requested policy")).font(Theme.caption).foregroundStyle(Theme.textTertiary)
            option(tr("Auto"), on: monitor.policiesAvailable && current == .auto) { monitor.setPolicy(.auto, fan: fan.id) }
            option(tr("Max"), on: monitor.policiesAvailable && isMax) { monitor.setPolicy(.fixed(rpm: .infinity), fan: fan.id) }.disabled(fan.validRange == nil)
            if monitor.policiesAvailable && isCustom {
                option(tr("Custom"), on: true) { MainWindow.show(.fans) }
            }
        }
    }

    func option(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Theme.caption.weight(on ? .semibold : .regular))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Theme.accent : Color.white.opacity(0.08)))
                .foregroundStyle(on ? Color.white : Theme.textPrimary)
        }
        .buttonStyle(.plain).disabled(monitor.helperBusy)
    }
}

// MARK: - Overview

struct OverviewView: View {
    @ObservedObject var monitor: Monitor
    @AppStorage(Settings.fahrenheit) private var fahrenheit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PulseCard(active: monitor.panelVisible)
            if let s = monitor.snapshot {
                VStack(spacing: 6) {
                    ForEach(SensorGroup.allCases, id: \.self) { g in
                        if let t = s.maxTemperature(in: g) {
                            HStack {
                                Text(groupName(g)).frame(width: 70, alignment: .leading)
                                Bar(value: t / 100, color: heatColor(t))
                                Text(tempText(t, fahrenheit: fahrenheit)).monospacedDigit().frame(width: 52, alignment: .trailing)
                            }
                            .font(Theme.body)
                        }
                    }
                }
                Divider()
                ForEach(monitor.sampledFans ?? []) { f in
                    HStack(spacing: 8) {
                        FanRow(fan: f)
                        QuickFanSwitch(monitor: monitor, fan: f)
                    }
                }
                if let b = s.battery { BatteryRow(battery: b, fahrenheit: fahrenheit) }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            TemperatureChart(history: monitor.history)
        }
    }
}

struct FanRow: View {
    let fan: FanReading
    var body: some View {
        HStack {
            Image(systemName: "fan").foregroundStyle(fan.manual == true ? Theme.caution : Theme.textSecondary)
            Text(fan.name).frame(width: 52, alignment: .leading)
            FanLoadIndicator(fan: fan)
            Text(tr("%1$@ rpm", FanControlPresentation.rpm(fan.rpm))).monospacedDigit().frame(width: 76, alignment: .trailing)
        }
        .font(Theme.body)
        .help(tr("%1$@–%2$@ rpm · %3$@", FanControlPresentation.rpm(fan.min), FanControlPresentation.rpm(fan.max), tr(fan.controlMode)))
    }
}

struct BatteryRow: View {
    let battery: BatteryInfo
    let fahrenheit: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: battery.charging ? "battery.100.bolt" : "battery.75").foregroundStyle(Theme.textSecondary)
            if let p = battery.percent { Text(String(format: "%.0f%%", p)) }
            if let t = battery.temperature { Text(tempText(t, fahrenheit: fahrenheit)).foregroundStyle(heatColor(t)) }
            if let w = battery.power { Text(String(format: "%+.1f W", w)) }
            Spacer()
            if let h = battery.health { Text(tr("health %1$@%%", String(format: "%.0f", h * 100))).foregroundStyle(Theme.textSecondary) }
            if let c = battery.cycleCount { Text(tr("%1$@ cycles", String(c))).foregroundStyle(Theme.textSecondary) }
        }
        .font(Theme.caption)
        .monospacedDigit()
    }
}

struct TemperatureChart: View {
    let history: [HistoryPoint]
    @AppStorage(Settings.fahrenheit) private var fahrenheit = false

    func temperature(_ c: Double) -> Double { fahrenheit ? c * 9 / 5 + 32 : c }

    var domain: ClosedRange<Double> {
        let values = history.flatMap { [$0.cpu, $0.gpu].compactMap { $0 } }.filter(\.isFinite)
        let lower = min(20, (values.min() ?? 20) - 5)
        let upper = max(105, (values.max() ?? 105) + 5)
        return temperature(lower)...temperature(upper)
    }

    var body: some View {
        Chart {
            ForEach(history) { p in
                if let c = p.cpu, c.isFinite {
                    LineMark(x: .value("Time", p.time), y: .value(fahrenheit ? "°F" : "°C", temperature(c)), series: .value("Sensor", "CPU"))
                        .foregroundStyle(by: .value("Sensor", "CPU"))
                }
                if let g = p.gpu, g.isFinite {
                    LineMark(x: .value("Time", p.time), y: .value(fahrenheit ? "°F" : "°C", temperature(g)), series: .value("Sensor", "GPU"))
                        .foregroundStyle(by: .value("Sensor", "GPU"))
                }
            }
        }
        .chartYScale(domain: domain)
        .chartYAxisLabel(fahrenheit ? "°F" : "°C")
        .chartOverlay { _ in
            if !history.contains(where: { $0.cpu?.isFinite == true || $0.gpu?.isFinite == true }) {
                Text(tr("Waiting for temperature readings…")).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute()) } }
        .chartLegend(position: .top, alignment: .trailing)
        .frame(height: 110)
    }
}

// MARK: - Sensors

/// Set by `--render-preview`: ImageRenderer cannot draw AppKit-backed scroll views.
var renderingPreview = false

struct SensorsView: View {
    @ObservedObject var monitor: Monitor
    /// False inside the main window, whose page scrolls.
    var scrolls = true
    @AppStorage(Settings.fahrenheit) private var fahrenheit = false

    var body: some View {
        if renderingPreview || !scrolls { list } else { ScrollView { list }.frame(height: 360) }
    }

    var list: some View {
        Group {
            LazyVStack(alignment: .leading, spacing: 3) {
                if let s = monitor.snapshot {
                    ForEach(SensorGroup.allCases, id: \.self) { g in
                        let rows = s.temperatures.filter { $0.group == g }
                        if !rows.isEmpty {
                            section(groupName(g))
                            ForEach(rows) { r in
                                row(r.name, key: r.key, value: tempText(r.value, fahrenheit: fahrenheit), color: heatColor(r.value))
                            }
                        }
                    }
                    electrical(tr("Power"), s.power, "%.2f W")
                    electrical(tr("Voltage"), s.voltages, "%.3f V")
                    electrical(tr("Current"), s.currents, "%.3f A")
                }
            }
        }
    }

    @ViewBuilder func electrical(_ title: String, _ rows: [Reading], _ f: String) -> some View {
        if !rows.isEmpty {
            section(title)
            ForEach(rows) { r in row(r.name, key: r.key, value: String(format: f, r.value), color: Theme.textPrimary) }
        }
    }

    func section(_ t: String) -> some View {
        Text(t).font(Theme.label).foregroundStyle(Theme.textTertiary).padding(.top, 6)
    }

    func row(_ name: String, key: String, value: String, color: Color) -> some View {
        HStack {
            Text(name)
            Spacer()
            if !key.hasPrefix("hid:") { Text(key).font(Theme.mono).foregroundStyle(Theme.textTertiary) }
            Text(value).monospacedDigit().foregroundStyle(color).frame(width: 70, alignment: .trailing)
        }
        .font(Theme.body)
    }
}

// MARK: - Fans

enum FanMode: String, CaseIterable, Identifiable {
    case auto = "Auto", fixed = "Fixed", curve = "Curve"
    var id: String { rawValue }
    var title: String { tr(rawValue) }
}

enum CurvePreset: String, CaseIterable, Identifiable {
    case quiet = "Quiet", balanced = "Balanced", performance = "Performance", custom = "Custom"
    var id: String { rawValue }
    var title: String { tr(rawValue) }
    var curve: FanCurve? {
        switch self {
        case .quiet: return .quiet
        case .balanced: return .balanced
        case .performance: return .performance
        case .custom: return nil
        }
    }
}

/// The Fans page: the live speed of every fan with its recent curve on top (the page's one
/// figure), then one control panel per fan, then the safety rule in a line.
struct FansView: View {
    @ObservedObject var monitor: Monitor

    private var missingFanIDs: [Int] {
        FanControlPresentation.missingFanIDs(readings: monitor.sampledFans, policies: monitor.policies,
                                            pending: monitor.pendingPolicies, state: monitor.fanControlState)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            helperBanner
            hero
            if let fans = monitor.sampledFans, !fans.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    SectionHeader(title: tr("Mode")) {
                        if fans.count > 1 && [.running, .outdated].contains(monitor.helperState) {
                            Button(tr("All fans to Auto")) { monitor.setPolicy(.auto, fan: -1) }
                                .buttonStyle(PillButtonStyle()).controlSize(.small).disabled(monitor.helperBusy)
                        }
                    }
                    ForEach(fans) { f in
                        // Always usable: without a helper, Apply queues the setting and starts setup.
                        FanControlCard(fan: f, policy: monitor.pendingPolicies[f.id] ?? monitor.policies[f.id] ?? .auto,
                                       enabled: !monitor.helperBusy, pending: monitor.pendingPolicies[f.id] != nil,
                                       policyAvailable: monitor.policiesAvailable, applying: monitor.applyingPolicies,
                                       controlState: monitor.fanControlState, checking: monitor.helperState == .unknown,
                                       showName: fans.count > 1) { monitor.setPolicy($0, fan: f.id) }
                    }
                }
            }
            ForEach(missingFanIDs, id: \.self) { id in
                missingFan(id)
            }
            if missingFanIDs.isEmpty, (monitor.sampledFans ?? []).isEmpty,
               let state = monitor.fanControlState, state.failure != nil || state.suspended {
                NoticeBanner(text: FanControlPresentation.observation(state, fan: -1))
            }
            Label(tr("Safety: sustained heat above %1$@ °C (%2$@ °C on Apple Silicon) pauses policies that reduce cooling. Full-speed cooling can continue. The helper attempts Auto on stopping; recovery failures are reported.",
                     String(Int(SafetyLimits.intel.ceiling)), String(Int(SafetyLimits.appleSilicon.ceiling))),
                  systemImage: "checkmark.shield")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
        }
        .onAppear { monitor.refreshHelper() }
    }

    func missingFan(_ id: Int) -> some View {
        let policy = FanControlPresentation.policy(monitor.pendingPolicies[id] ?? monitor.policies[id] ?? .auto)
        let checked = monitor.fanControlState?.observations[id]?.checkedAt
        let detail = [tr("No current reading for this fan. Saved settings and last checks are shown below."),
                      FanControlPresentation.observation(monitor.fanControlState, fan: id),
                      checked.flatMap { $0.timeIntervalSince1970.isFinite ? tr("Checked at %1$@", $0.formatted(date: .numeric, time: .standard)) : nil }]
            .compactMap { $0 }.joined(separator: "\n")
        return InspectorPanel {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "fan").foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Fan %1$@ · saved state", String(id))).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary)
                    Text(monitor.pendingPolicies[id] != nil ? tr("Waiting for helper: %1$@", policy) :
                            monitor.policiesAvailable ? tr("Requested policy: %1$@", policy) : tr("Requested policy unavailable"))
                        .font(Theme.secondary).foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
                InfoButton(text: detail)
            }
            .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
        }
    }

    /// Every fan's speed in big figures over the last ten minutes of speed.
    var hero: some View {
        InspectorPanel {
            if let fans = monitor.sampledFans {
                if fans.isEmpty {
                    EmptyState(symbol: "fan", title: tr("This Mac has no fans."))
                } else {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(fans.enumerated()), id: \.element.id) { i, f in
                            if i > 0 { Rectangle().fill(Theme.hairline).frame(width: 1) }
                            FanFigure(fan: f, checking: monitor.helperState == .unknown)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: Theme.Space.m) {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        SkeletonBar(width: 60, height: 9)
                        SkeletonBar(width: 150, height: 26)
                        Text(monitor.fanEmptyMessage).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                }
                .padding(Theme.Space.l)
            }
            InspectorDivider(inset: 0)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(tr("Fan speed, last 10 minutes")).font(Theme.label).foregroundStyle(Theme.textTertiary)
                FanChart(history: monitor.history)
            }
            .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
        }
    }

    /// Progress states are a quiet notice; states that need the person get a panel with its buttons.
    @ViewBuilder var helperBanner: some View {
        if monitor.uninstallingHelper {
            notice(tr("Uninstalling the system helper…"), tr("Fan, sleep, network and charging controls are being restored before removal. Read-only sensor viewing remains available."))
        } else {
        switch monitor.helperState {
        case .running:
            EmptyView()
        case .outdated:
            setupCard(icon: "arrow.triangle.2.circlepath", title: tr("System helper update required"),
                      body: tr("Check the connection again, or reinstall the helper. macOS may ask for an administrator password.")
                        + " " + tr("Reinstalling keeps fan settings but ends active charging and low-latency sessions."),
                      primary: (tr("Retry"), { monitor.refreshHelper() }),
                      secondary: (tr("Reinstall…"), { monitor.installHelperWithPassword() }))
        case .notRunning:
            setupCard(icon: "exclamationmark.triangle", title: tr("Could not connect to the system helper"),
                      body: tr("Check the connection again, or reinstall the helper. macOS may ask for an administrator password.")
                        + " " + tr("Reinstalling keeps fan settings but ends active charging and low-latency sessions."),
                      primary: (tr("Retry"), { monitor.refreshHelper() }),
                      secondary: (tr("Reinstall…"), { monitor.installHelperWithPassword() }))
        case .unknown:
            notice(tr("Checking the system helper…"), tr("Reading the helper’s status. You can keep viewing sensor readings."))
        case .notInstalled, .needsApproval:
            setupCard(icon: "fan", title: tr("Let Thermo control the fans"),
                      body: tr("Thermo's system helper manages fans, lid-closed wake, network low latency and charging protection. Fan requests stay within device ranges and recovery failures are reported. macOS may ask for an administrator password."),
                      primary: (tr("Allow…"), { monitor.beginSetup() }))
        }
        }
    }

    /// One line with a spinner; the longer explanation sits behind the (?).
    func notice(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                ProgressView().controlSize(.small)
                Text(title + (monitor.settingUp && !monitor.uninstallingHelper ? " " + tr("Setting up…") : ""))
                    .font(Theme.secondary).foregroundStyle(Theme.textSecondary)
                InfoButton(text: body)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
            .background(RoundedRectangle(cornerRadius: Theme.radiusSmall + 2, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall + 2, style: .continuous).strokeBorder(Theme.hairline))
            pendingNote
        }
    }

    @ViewBuilder var pendingNote: some View {
        if !monitor.pendingPolicies.isEmpty {
            Text(tr("Your fan setting is applied as soon as the helper is ready."))
                .font(Theme.caption).foregroundStyle(Theme.caution).padding(.horizontal, 2)
        }
    }

    func setupCard(icon: String, title: String, body: String, primary: (String, () -> Void)?, secondary: (String, () -> Void)? = nil) -> some View {
        InspectorPanel {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                IconTile(symbol: icon, color: Theme.caution, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Theme.Space.xs) {
                        Text(title).font(Theme.rowTitle.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                        InfoButton(text: body)
                    }
                    if !monitor.pendingPolicies.isEmpty {
                        Text(tr("Your fan setting is applied as soon as the helper is ready."))
                            .font(Theme.caption).foregroundStyle(Theme.caution)
                    } else if monitor.settingUp || monitor.uninstallingHelper {
                        Text(tr(monitor.uninstallingHelper ? "Uninstalling…" : "Setting up…")).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer(minLength: Theme.Space.s)
                if !renderingPreview {
                    if monitor.settingUp || monitor.uninstallingHelper { ProgressView().controlSize(.small) }
                    if let secondary {
                        Button(secondary.0, action: secondary.1).buttonStyle(PillButtonStyle()).controlSize(.small)
                            .disabled(monitor.settingUp || monitor.helperBusy)
                    }
                    if let primary {
                        Button(primary.0, action: primary.1).buttonStyle(PillButtonStyle(prominent: true)).controlSize(.small)
                            .disabled(monitor.settingUp || monitor.helperBusy)
                    }
                }
            }
            .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
        }
    }
}

/// One fan in the hero: name, its speed in big figures, how far it is towards full speed.
struct FanFigure: View {
    let fan: FanReading
    var checking = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "fan").font(.system(size: 11, weight: .medium)).accessibilityHidden(true)
                Text(fan.name).font(Theme.label)
                if fan.manual == true { StatusTag(text: tr("manual"), color: Theme.caution) }
            }
            .foregroundStyle(Theme.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                if checking && (fan.rpm ?? 0) == 0 {
                    // A zero while the helper is still being read says nothing yet.
                    Text("—").font(Theme.figure(.hero)).foregroundStyle(Theme.textTertiary)
                } else {
                    Text(FanControlPresentation.rpm(fan.rpm)).font(Theme.figure(.hero)).foregroundStyle(Theme.textPrimary)
                        .contentTransition(.numericText())
                        .animation(Theme.standard.unlessReduced(reduceMotion), value: fan.rpm)
                }
                // The unit alone, from the same localized pattern the rest of the app uses.
                Text(tr("%1$@ rpm", "").trimmingCharacters(in: .whitespaces)).font(Theme.label).foregroundStyle(Theme.textTertiary)
            }
            FanLoadIndicator(fan: fan).frame(maxWidth: 220).accessibilityHidden(true)
            Text(tr("%1$@–%2$@ rpm · %3$@", FanControlPresentation.rpm(fan.min), FanControlPresentation.rpm(fan.max), tr(fan.controlMode)))
                .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct FanControlCard: View {
    let fan: FanReading
    let policy: FanPolicy
    let enabled: Bool
    var pending = false
    var policyAvailable = true
    var applying = false
    var controlState: FanControlState?
    var checking = false
    var showName = true
    let apply: (FanPolicy) -> Void

    @State private var mode: FanMode = .auto
    @State private var rpm: Double = 0
    @State private var preset: CurvePreset = .balanced
    @State private var customCurve = "50:min,70:3000,85:max"
    @State private var sensor: CurveSensor = .cpu
    @State private var curveError: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        InspectorPanel {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.m) {
                    if showName {
                        Text(fan.name).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary)
                    }
                    ThermoTabs(selection: $mode, options: FanMode.allCases.map { ($0, $0.title) }, label: tr("Mode"))
                        .disabled(!enabled)
                    Spacer(minLength: 0)
                }
                editor
            }
            .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
            .animation(Theme.standard.unlessReduced(reduceMotion), value: mode)
            InspectorDivider(inset: 0)
            HStack(spacing: Theme.Space.s) {
                status
                Spacer(minLength: Theme.Space.s)
                Button(applying ? tr("Sending…") : tr("Apply")) { applyCurrent() }
                    .buttonStyle(PillButtonStyle(prominent: true)).controlSize(.small)
                    .disabled(!enabled || (mode != .auto && fan.validRange == nil))
            }
            .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s)
        }
        .disabled(!enabled)
        .onAppear(perform: load)
        // The helper's policies arrive after the card appears (at launch, after a helper restart):
        // Load the desired policy so Apply does not resend stale editor defaults.
        .onChange(of: policy) { _ in load() }
    }

    @ViewBuilder var editor: some View {
        switch mode {
        case .auto:
            EmptyView()
        case .fixed:
            if let range = fan.validRange {
                HStack(spacing: Theme.Space.m) {
                    Slider(value: $rpm, in: range.min...max(range.max, range.min + 1), step: 100).accessibilityLabel(tr("Fan speed"))
                    Text(tr("%1$@ rpm", String(format: "%.0f", rpm))).font(Theme.figure(.row))
                        .foregroundStyle(Theme.textPrimary).frame(width: 80, alignment: .trailing)
                        .contentTransition(.numericText())
                }
                .transition(.opacity)
            }
        case .curve:
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) {
                    Picker(tr("Preset"), selection: $preset) { ForEach(CurvePreset.allCases) { Text($0.title).tag($0) } }
                        .fixedSize()
                    Picker(tr("Sensor"), selection: $sensor) { ForEach(CurveSensor.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) } }
                        .fixedSize()
                    Spacer(minLength: 0)
                }
                .pickerStyle(.menu)
                if preset == .custom {
                    HStack(spacing: Theme.Space.xs) {
                        TextField("TEMP:RPM,…", text: $customCurve).textFieldStyle(.roundedBorder).font(Theme.mono)
                            .accessibilityLabel(tr("Custom fan curve"))
                            .onChange(of: customCurve) { _ in curveError = nil }
                        InfoButton(text: tr("Curve temperatures use °C. RPM is limited to this fan’s range."))
                    }
                } else if let c = preset.curve {
                    Text(c.points.map { "\(Int($0.temperature))°C→\($0.rpm.isInfinite ? "max" : $0.rpm == 0 ? "min" : String(Int($0.rpm)))" }.joined(separator: "  "))
                        .font(Theme.mono).foregroundStyle(Theme.textTertiary)
                }
                if let curveError { Text(curveError).font(Theme.caption).foregroundStyle(Theme.danger) }
            }
            .transition(.opacity)
        }
        if mode != .auto && fan.validRange == nil {
            Text(tr("Fan range unavailable")).font(Theme.caption).foregroundStyle(Theme.textTertiary)
        }
    }

    /// One line for what was asked of the fan; what the hardware check found is behind the (?).
    @ViewBuilder var status: some View {
        if checking {
            SkeletonBar(width: 160, height: 8)
        } else {
            let checked = controlState?.observations[fan.id]?.checkedAt
            let detail = [FanControlPresentation.observation(controlState, fan: fan.id),
                          checked.flatMap { $0.timeIntervalSince1970.isFinite ? tr("Checked at %1$@", $0.formatted(date: .numeric, time: .standard)) : nil }]
                .compactMap { $0 }.joined(separator: "\n")
            HStack(spacing: Theme.Space.xs) {
                Circle().fill(pending ? Theme.caution : policyAvailable ? Theme.good : Theme.textTertiary).frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(pending ? tr("Waiting for helper: %1$@", policyText) : policyAvailable ? tr("Requested policy: %1$@", policyText) : tr("Requested policy unavailable"))
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                if !detail.isEmpty { InfoButton(text: detail) }
            }
        }
    }

    var policyText: String {
        FanControlPresentation.policy(policy)
    }

    func load() {
        curveError = nil
        rpm = fan.validRange.map { min($0.max, max($0.min, fan.target ?? fan.rpm ?? $0.min)) } ?? 0
        switch policy {
        case .auto: mode = .auto
        case .fixed(let r): mode = .fixed; rpm = fan.validRange.map { r.isInfinite ? $0.max : min($0.max, max($0.min, r)) } ?? 0
        case .curve(let c):
            mode = .curve
            sensor = c.sensor
            preset = CurvePreset.allCases.first { $0.curve?.points == c.points } ?? .custom
            if preset == .custom { customCurve = c.pointsText }
        }
    }

    func applyCurrent() {
        curveError = nil
        switch mode {
        case .auto: apply(.auto)
        case .fixed: apply(.fixed(rpm: rpm))
        case .curve:
            do {
                var c = try preset.curve ?? FanCurve(parsing: customCurve)
                c.sensor = sensor
                apply(.curve(c))
            } catch {
                curveError = "\(error)"
            }
        }
    }
}

struct FanChart: View {
    let history: [HistoryPoint]
    var body: some View {
        let samples = FanChartSample.samples(history)
        Chart {
            ForEach(samples) { p in
                AreaMark(x: .value("Time", p.time), y: .value("RPM", p.rpm), series: .value("Segment", "\(p.fan):\(p.segment)"))
                    .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.22), Theme.accent.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", p.time), y: .value("RPM", p.rpm), series: .value("Segment", "\(p.fan):\(p.segment)"))
                    .foregroundStyle(by: .value("Fan", "Fan \(p.fan + 1)"))
                    .interpolationMethod(.monotone)
            }
        }
        .chartForegroundStyleScale(range: [Theme.accent, Color(red: 0.35, green: 0.80, blue: 0.78), Theme.caution])
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in
            AxisGridLine().foregroundStyle(Theme.hairline)
            AxisValueLabel(format: .dateTime.hour().minute()).foregroundStyle(Theme.textTertiary)
        } }
        .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in
            AxisGridLine().foregroundStyle(Theme.hairline)
            AxisValueLabel().foregroundStyle(Theme.textTertiary)
        } }
        .chartLegend(Set(samples.map(\.fan)).count > 1 ? .visible : .hidden)
        .chartOverlay { _ in
            if samples.isEmpty {
                Text(tr("Checking…")).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 120)
    }
}

struct FanLoadIndicator: View {
    let fan: FanReading
    var body: some View {
        if let load = fan.load {
            Bar(value: load, color: fan.manual == nil ? Theme.textTertiary : fan.manual == true ? Theme.caution : Theme.accent)
        } else {
            Capsule().fill(Color.white.opacity(0.07)).frame(height: 4).accessibilityLabel(tr("unknown"))
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var disk: DiskModel
    @ObservedObject var monitor: Monitor
    @AppStorage(Settings.showInDock) private var showInDock = true
    @AppStorage(PulseRecorder.alertsKey) private var slowdownAlerts = true
    @ObservedObject var updates: Updates
    @ObservedObject private var notifications = NotificationAccess.shared
    @ObservedObject private var loginItem = LoginItemAccess.shared
    @AppStorage(MenuBarPreferences.primaryKey) private var menuPrimary = "cpu"
    @AppStorage(MenuBarPreferences.secondaryKey) private var menuSecondary = "none"
    @AppStorage(MenuBarPreferences.presentationKey) private var menuPresentation = "both"
    @AppStorage(MenuBarPreferences.layoutKey) private var menuLayout = "horizontal"
    @AppStorage(MenuBarPreferences.leftKey) private var menuLeft = "panel"
    @AppStorage(MenuBarPreferences.rightKey) private var menuRight = "menu"
    @AppStorage(Settings.interval) private var interval = 2.0
    @AppStorage(Settings.alertsEnabled) private var alertsEnabled = false
    @AppStorage(Settings.alertThreshold) private var alertThreshold = 90.0
    @AppStorage(Settings.fahrenheit) private var fahrenheit = false
    @AppStorage(L10n.defaultsKey) private var language = "system"

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            // Features with their own panel: one group of rows, each opening its panel.
            section(tr("Tools")) {
                row(tr("Search apps and files"), labelControl: false) {
                    Button(tr("Search settings…")) { LocalSearchPanel.shared.show(settings: true) }.controlSize(.small)
                }
                CleanScreenButton()
                InspectorDivider(inset: 46)
                IdleAwakeButton()
                InspectorDivider(inset: 46)
                AWDLButton()
                InspectorDivider(inset: 46)
                BatteryCareButton()
                InspectorDivider(inset: Theme.Space.l)
                row(tr("Disk Cleanup"), last: true, labelControl: false) {
                    CleanupProtectionsButton(disk: disk).controlSize(.small)
                }
            }
            section(tr("General")) {
                row(tr("Language")) {
                    Picker("", selection: $language) {
                        Text(tr("System")).tag("system")
                        ForEach(Language.allCases) { Text($0.displayName).tag($0.rawValue) }
                    }
                    .onChange(of: language) { L10n.apply(preference: $0) }
                }
                Group {
                    row(tr("Primary metric")) {
                        Picker(tr("Primary metric"), selection: $menuPrimary) { ForEach(MenuMetric.allCases) { Text($0.label).tag($0.rawValue) } }.labelsHidden()
                    }
                    row(tr("Second metric")) {
                        Picker(tr("Second metric"), selection: $menuSecondary) {
                            Text(tr("No second metric")).tag("none")
                            ForEach(MenuMetric.allCases) { Text($0.label).tag($0.rawValue) }
                        }.labelsHidden()
                    }
                    row(tr("Menu bar shows")) {
                        Picker(tr("Menu bar shows"), selection: $menuPresentation) {
                            Text(tr("Icon and live data")).tag("both")
                            Text(tr("Icon only")).tag("icon")
                            Text(tr("Live data only")).tag("data")
                        }.labelsHidden()
                    }
                    row(tr("Menu bar layout")) {
                        Picker(tr("Menu bar layout"), selection: $menuLayout) {
                            Text(tr("Horizontal")).tag("horizontal")
                            Text(tr("Two lines")).tag("stacked")
                        }.labelsHidden()
                    }
                    row(tr("Left click")) {
                        Picker(tr("Left click"), selection: $menuLeft) {
                            Text(tr("Panel")).tag("panel"); Text(tr("Main console")).tag("console"); Text(tr("Menu")).tag("menu")
                        }.labelsHidden()
                    }
                    row(tr("Right click")) {
                        Picker(tr("Right click"), selection: $menuRight) {
                            Text(tr("Panel")).tag("panel"); Text(tr("Main console")).tag("console"); Text(tr("Menu")).tag("menu")
                        }.labelsHidden()
                    }
                }
                row(tr("Update every")) {
                    Picker("", selection: $interval) {
                        Text("0.5 s").tag(0.5); Text("1 s").tag(1.0); Text("2 s").tag(2.0); Text("5 s").tag(5.0)
                    }
                    .onChange(of: interval) { _ in monitor.reschedule() }
                }
                row(tr("Fahrenheit")) { Toggle("", isOn: $fahrenheit) }
                row(tr("Show in Dock")) { Toggle("", isOn: $showInDock) }
                row(tr("Launch at login"), last: true) {
                    Toggle("", isOn: Binding(get: { loginItem.requested }, set: { loginItem.setRequested($0) }))
                        .disabled(loginItem.state == .unknown || loginItem.state == .unavailable)
                }
            }
            if loginItem.state == .needsApproval || loginItem.state == .unavailable || loginItem.error != nil {
                statusPanel {
                    if loginItem.state == .needsApproval {
                        HStack {
                            Label(tr("Launch at login is waiting for macOS approval."), systemImage: "hourglass")
                            Spacer(minLength: Theme.Space.s)
                            Button(tr("Open Login Items settings")) { loginItem.openSettings() }
                                .buttonStyle(PillButtonStyle()).controlSize(.small)
                        }
                    } else if loginItem.state == .unavailable {
                        Label(tr("macOS could not find Thermo’s login item. Open the installed app and try again."), systemImage: "exclamationmark.triangle")
                    }
                    if let error = loginItem.error {
                        Text(error).foregroundStyle(Theme.caution).textSelection(.enabled)
                    }
                }
            }
            section(tr("Alerts")) {
                row(tr("Warn me before my Mac gets slow")) {
                    Toggle("", isOn: $slowdownAlerts)
                        .onChange(of: slowdownAlerts) { enabled in if enabled { notifications.request() } }
                }
                row(tr("Alert when hot"), last: !alertsEnabled) {
                    Toggle("", isOn: $alertsEnabled)
                        .onChange(of: alertsEnabled) { on in if on { Monitor.requestNotificationPermission() } }
                }
                if alertsEnabled {
                    row(fahrenheit ? tr("Threshold: %1$@ °F", Settings.thresholdText(alertThreshold, fahrenheit: true)) : tr("Threshold: %1$@ °C", Settings.thresholdText(alertThreshold, fahrenheit: false)), last: true) {
                        Stepper("", value: Binding(
                            get: {
                                let value = Settings.thresholdValue(alertThreshold)
                                return fahrenheit ? value * 9 / 5 + 32 : value
                            },
                            set: { alertThreshold = Settings.thresholdValue(fahrenheit ? ($0 - 32) * 5 / 9 : $0) }
                        ), in: fahrenheit ? 140...221 : 60...105, step: fahrenheit ? 1.8 : 1)
                            .accessibilityValue(Text(Settings.thresholdText(alertThreshold, fahrenheit: fahrenheit)))
                    }
                }
            }
            if slowdownAlerts || alertsEnabled {
                notificationStatus
            }
            section(tr("AI agents")) {
                AgentAccessRow().padding(Theme.Space.l)
            }
            section(tr("System helper")) {
                row(tr("System helper: %1$@", helperText), last: true, labelControl: false) {
                    if [.running, .notRunning, .needsApproval, .outdated].contains(monitor.helperState) {
                        HStack(spacing: 8) {
                            if monitor.uninstallingHelper || monitor.settingUp {
                                ProgressView().controlSize(.small)
                                Text(tr(monitor.uninstallingHelper ? "Uninstalling…" : "Setting up…")).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                            }
                            if monitor.helperState != .needsApproval {
                                Button(tr("Reinstall…")) { monitor.installHelperWithPassword() }
                                    .buttonStyle(PillButtonStyle()).controlSize(.small)
                                    .help(tr("Reinstalling keeps fan settings but ends active charging and low-latency sessions."))
                                    .disabled(monitor.helperBusy || monitor.settingUp)
                            }
                            Button(tr("Uninstall")) { monitor.uninstallHelper() }
                                .buttonStyle(PillButtonStyle()).controlSize(.small)
                                .disabled(monitor.helperBusy || monitor.settingUp)
                        }
                    }
                }
            }
            section(tr("About")) {
                if updates.enabled {
                    row(tr("Check for updates automatically")) {
                        Toggle("", isOn: Binding(get: { updates.automaticallyChecks }, set: { updates.automaticallyChecks = $0 }))
                    }
                }
                row("Thermo \(AppInfo.version)", labelControl: false) {
                    HStack {
                        if updates.enabled {
                            Button(tr("Check for Updates…")) { updates.checkForUpdates() }
                                .buttonStyle(PillButtonStyle(prominent: true)).controlSize(.small)
                                .disabled(!updates.canCheck)
                                .help(updates.canCheck ? tr("Checks for a newer version of Thermo.") : tr("An update check is temporarily unavailable."))
                        }
                        Button(tr("Quit Thermo")) { NSApp.terminate(nil) }
                            .buttonStyle(PillButtonStyle()).controlSize(.small)
                    }
                }
                row(tr("App package source"), last: true, labelControl: false) {
                    if let commit = AppInfo.buildMetadata.sourceCommit {
                        Text(commit + " · " + tr(AppInfo.workingTreeLabel))
                            .font(Theme.mono).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                    } else { Text(tr("Unknown")).font(Theme.secondary).foregroundStyle(Theme.textTertiary) }
                }
            }
        }
        .toggleStyle(.switch)
        .pickerStyle(.menu)
        .onAppear { notifications.refresh(); loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            notifications.refresh(); loginItem.refresh()
        }
    }

    @ViewBuilder var notificationStatus: some View {
        statusPanel {
            switch notifications.state {
            case .unknown:
                Label(tr("Checking notification permission…"), systemImage: "hourglass")
            case .unavailable:
                Label(tr("Notifications require an app bundle."), systemImage: "bell.slash")
            case .notRequested:
                Label(tr("Notification permission has not been requested."), systemImage: "bell.badge")
                Button(tr("Allow notifications")) { notifications.request() }
                    .buttonStyle(PillButtonStyle()).controlSize(.small).disabled(notifications.requesting)
            case .denied:
                Label(tr("Notifications are disabled in macOS."), systemImage: "bell.slash")
                Button(tr("Open notification settings")) { notifications.openSettings() }
                    .buttonStyle(PillButtonStyle()).controlSize(.small)
            case .bannersDisabled:
                Label(tr("Notifications are authorized, but banners are disabled."), systemImage: "bell")
                Button(tr("Open notification settings")) { notifications.openSettings() }
                    .buttonStyle(PillButtonStyle()).controlSize(.small)
            case .allowed:
                Label(tr("macOS has authorized notifications."), systemImage: "checkmark.circle")
            }
            if let error = notifications.error {
                Text(error).foregroundStyle(Theme.caution).textSelection(.enabled)
            }
            if notifications.requesting { ProgressView().controlSize(.small) }
        }
    }

    /// A status note under a group: quiet text, its buttons at hand.
    func statusPanel<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) { content() }
            .font(Theme.secondary).foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
            .glass(radius: Theme.radius)
    }

    /// One group of settings, the way System Settings draws them: a quiet title, then the rows in one panel.
    func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        let rows = content()
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader(title: title)
            InspectorPanel { rows }
        }
    }

    func row<C: View>(_ title: String, last: Bool = false, labelControl: Bool = true, @ViewBuilder _ control: () -> C) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.m) {
                Text(title).font(Theme.body).foregroundStyle(Theme.textPrimary)
                Spacer(minLength: Theme.Space.s)
                if labelControl {
                    control().labelsHidden().fixedSize().accessibilityLabel(title)
                } else {
                    control().labelsHidden().fixedSize()
                }
            }
            .padding(.horizontal, Theme.Space.l).frame(minHeight: 44)
            if !last { InspectorDivider(inset: Theme.Space.l) }
        }
    }

    var helperText: String {
        switch monitor.helperState {
        case .running: return tr("running")
        case .notRunning: return tr("not responding")
        case .notInstalled: return tr("not installed")
        case .needsApproval: return tr("waiting for approval")
        case .outdated: return tr("outdated")
        case .unknown: return "…"
        }
    }
}
