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
    guard let c else { return .secondary }
    return c >= 85 ? .red : c >= 65 ? .orange : .green
}

/// Lightweight level bar (cheaper than ProgressView and tinted per value).
struct Bar: View {
    let value: Double
    var color: Color = .accentColor
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color).frame(width: g.size.width * min(1, max(0, value.isFinite ? value : 0)))
            }
        }
        .frame(height: 6)
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

    var body: some View {
        let _ = L10n.apply(preference: language)
        content.id(language)  // rebuild every string in the new language
            .onAppear { panel.setActive(monitor.panelVisible || renderingPreview) }
            .onChange(of: monitor.panelVisible) { panel.setActive($0) }
    }

    var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if monitor.iconHidden {
                // The menu bar icon is behind the notch; say how to get it back.
                Label(tr("The menu bar icon is hidden behind the notch. Hold ⌘ and drag other icons out of the menu bar to make room, or open Thermo from the Dock."),
                      systemImage: "eye.slash")
                    .font(.caption).foregroundStyle(.orange)
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
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.055)))
            }
            if let err = monitor.lastError {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(3)
                    .onTapGesture { monitor.lastError = nil }
            }
            Divider()
            if !renderingPreview {
                HStack { CleanScreenButton();AWDLButton() }
                if monitor.snapshot?.battery != nil { BatteryCareButton() }
            }
            footer
        }
        .padding(12)
        .frame(width: 372)
        .background(LinearGradient(colors: [Color(red: 0.11, green: 0.10, blue: 0.20), Color(red: 0.06, green: 0.09, blue: 0.17)],
                                   startPoint: .top, endPoint: .bottom))
        .environment(\.colorScheme, .dark)
    }

    // MARK: Header: how hot, why, and who

    var header: some View {
        let hot = monitor.snapshot?.maximumKnownTemperature
        let current = pulse.current
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(tempText(hot, fahrenheit: fahrenheit))
                    .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(heatColor(hot))
                Text(current == nil ? tr("Checking…") : verdictWord)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(current == nil ? .white.opacity(0.5) : pulse.severity)
                Spacer()
                if let w = monitor.snapshot?.systemPower {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(String(format: "%.1f W", w)).font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                        Text(tr("System")).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            if let current, let why = OverviewPage.sourceText(current) ?? current.culpritText {
                Text(why).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 5) {
                ForEach([panel.chip, PanelFormat.gb(panel.memoryTotal) + " GB", panel.macOS] + (PanelModel.uptime.map { [PanelFormat.uptime($0)] } ?? []), id: \.self) { fact in
                    Text(fact).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.07)))
                }
            }
        }
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
        return PanelCard(title: "CPU", symbol: "cpu", tint: .green, badge: s?.cpu.map { tempText($0, fahrenheit: fahrenheit) },
                         badgeTint: heatColor(s?.cpu)) {
            BigValue(value: panel.cpu.last.map { String(format: "%.0f", $0) } ?? "—", unit: "%")
            Sparkline(values: panel.cpu, top: 100, color: .green)
            Text([busy.map { tr("load %1$@× per core", String(format: "%.1f", $0)) }, s?.cpuPower.map { String(format: "%.1f W", $0) }]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
        }
    }

    var gpuCard: some View {
        let s = monitor.snapshot
        return PanelCard(title: "GPU", symbol: "square.stack.3d.up", tint: .orange, badge: s?.gpu.map { tempText($0, fahrenheit: fahrenheit) },
                         badgeTint: heatColor(s?.gpu)) {
            BigValue(value: panel.gpu.last.map { String(format: "%.0f", $0) } ?? "—", unit: panel.gpu.isEmpty ? nil : "%")
            Sparkline(values: panel.gpu, top: 100, color: .orange)
            Text(panel.gpu.isEmpty ? tr("not reported") : (panel.gpu.last ?? 0) >= 50 ? tr("busy") : tr("light"))
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
        }
    }

    var memoryCard: some View {
        let m = SystemStats.memory()
        let pressure = pulse.current?.memory ?? .unknown
        return PanelCard(title: tr("Memory"), symbol: "memorychip", tint: .yellow, badge: MachinePulse.memoryName(pressure),
                         badgeTint: pressure == .critical ? .red : pressure == .warning ? .orange : .white.opacity(0.6)) {
            BigValue(value: panel.memory.last.map { String(format: "%.0f", $0) } ?? "—", unit: "%")
            Sparkline(values: panel.memory, top: 100, color: .yellow)
            Text([m.map { PanelFormat.gb($0.usedBytes) + " / " + PanelFormat.gb($0.totalBytes) + " GB" },
                  pulse.current.flatMap { $0.swapUsedMB > 0 ? tr("swap %1$@", MemoryFormat.string(mebibytes: $0.swapUsedMB)) : nil }]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
        }
    }

    var diskCard: some View {
        let d = SystemStats.disk()
        let used = d.map { 1 - Double($0.freeBytes) / Double(max(1, $0.totalBytes)) } ?? 0
        return PanelCard(title: tr("Free space"), symbol: "internaldrive", tint: .cyan,
                         badge: d.map { ByteFormat.string($0.totalBytes) }) {
            BigValue(value: d.map { ByteFormat.string($0.freeBytes) } ?? "—")
            UsageBar(fraction: used, color: used > 0.9 ? .orange : .cyan)
            Text(d.map { tr("%1$@ used · %2$@", ByteFormat.string($0.totalBytes - $0.freeBytes), String(format: "%.0f%%", used * 100)) } ?? "")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
        }
    }

    var networkCard: some View {
        let (down, unit) = PanelFormat.rate(panel.download.last)
        let (up, upUnit) = PanelFormat.rate(panel.upload)
        return PanelCard(title: tr("Network"), symbol: "network", tint: .blue) {
            BigValue(value: down, unit: unit)
            Sparkline(values: panel.download, color: .blue)
            Text(tr("upload %1$@", up + " " + upUnit)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
        }
    }

    var fanCard: some View {
        let fans = monitor.snapshot?.fans ?? []
        let top = fans.filter { $0.rpm != nil }.max { $0.rpm! < $1.rpm! }
        return PanelCard(title: tr("Fans"), symbol: "fan", tint: .teal,
                         badge: top?.load.map { String(format: "%.0f%%", $0 * 100) }) {
            BigValue(value: top.map { (fans.contains { $0.rpm == nil } ? "≥ " : "") + FanControlPresentation.rpm($0.rpm) } ?? "—", unit: top == nil ? nil : "RPM")
            if fans.isEmpty {
                Text(tr("No fans")).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
            } else if monitor.policiesAvailable {
                let policies = fans.map { monitor.pendingPolicies[$0.id] ?? monitor.policies[$0.id] ?? .auto }
                let allAuto = policies.allSatisfy { $0 == .auto }
                let allMax = zip(fans, policies).allSatisfy { fan, policy in
                    if case .fixed(let rpm) = policy, let range=fan.validRange { return rpm.isInfinite || rpm >= range.max } else { return false }
                }
                Text(tr("Requested policy")).font(.system(size:10)).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    PanelButton(title: tr("Auto"), on: allAuto) { fans.forEach { monitor.setPolicy(.auto, fan: $0.id) } }
                    PanelButton(title: tr("Max"), on: allMax) { fans.forEach { monitor.setPolicy(.fixed(rpm: .infinity), fan: $0.id) } }
                        .disabled(fans.contains { $0.validRange == nil })
                }
                .disabled(monitor.helperBusy).padding(.top, 4)
            } else {
                Text(tr(fans.contains { $0.manual == true } ? "manual" : fans.contains { $0.manual == nil } ? "unknown" : "auto"))
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
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
        return PanelCard(title: tr("Battery"), symbol: b.charging ? "battery.100.bolt" : "battery.75", tint: (b.percent ?? 100) < 20 ? .red : .green,
                         badge: b.health.map { tr("health %1$@%%", String(format: "%.0f", $0 * 100)) }) {
            HStack(alignment: .firstTextBaseline) {
                BigValue(value: b.percent.map { String(format: "%.0f", $0) } ?? "—", unit: "%")
                Spacer()
                Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
            }
        }
    }

    /// The busiest programs, each with the project and agent behind it.
    var programs: some View {
        let hogs = Array((pulse.current?.hogs ?? []).sorted { $0.cpu > $1.cpu }.prefix(5))
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(tr("Busiest programs")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                Spacer()
                Text(tr("Memory")).frame(width: 64, alignment: .trailing)
                Text("CPU").frame(width: 46, alignment: .trailing)
            }
            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).padding(.bottom, 4)
            if hogs.isEmpty {
                Text(pulse.current == nil ? tr("Checking…") : tr("Nothing is busy."))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).padding(.vertical, 6)
            }
            ForEach(hogs) { h in
                Button { MainWindow.show(.compute(false)) } label: {
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(h.name).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                            if let origin = Self.origin(h) {
                                Text(origin).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        Text(MemoryFormat.string(kibibytes: h.memoryKB)).font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.7)).frame(width: 64, alignment: .trailing)
                        Text(String(format: "%.0f", h.cpu)).font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(h.cpu >= 100 ? Color.red : h.cpu >= 50 ? .orange : .white.opacity(0.8))
                            .frame(width: 46, alignment: .trailing)
                    }
                    .padding(.vertical, 4).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
    }

    /// "thermo · Claude Code": the working folder and a currently observed ancestor.
    static func origin(_ h: MachinePulse.Hog) -> String? {
        let folder = h.project.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty || $0 == "~" ? nil : $0 }
        let parts = [folder, h.owner].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Footer

    var footer: some View {
        HStack(spacing: 6) {
            PanelButton(title: tr("Open Console"), symbol: "macwindow", prominent: true) { MainWindow.show(.overview) }
            Spacer()
            shortcut("internaldrive", tr("Disk Cleanup"), .disk(.home))
            shortcut("stethoscope", tr("AI Agent Diagnostics"), .agents(.home))
            Button { TabQuickAction.request() } label: { Image(systemName: "archivebox").frame(width: 22) }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).help(tr("Save and close background tabs"))
            shortcut("clock.arrow.circlepath", tr("History"), .history)
            shortcut("gearshape", tr("Settings"), .settings)
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power").frame(width: 22) }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).help(tr("Quit Thermo"))
        }
        .padding(.top, 2)
    }

    func shortcut(_ symbol: String, _ title: String, _ page: MainPage) -> some View {
        Button { MainWindow.show(page) } label: { Image(systemName: symbol).frame(width: 22) }
            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).help(title).accessibilityLabel(title)
    }
}

/// Auto or full speed in one click; anything finer is in the main window's Fans page.
struct QuickFanSwitch: View {
    @ObservedObject var monitor: Monitor
    let fan: FanReading

    /// These buttons select desired policies; register observations are separate.
    var current: FanPolicy { monitor.pendingPolicies[fan.id] ?? monitor.policies[fan.id] ?? .auto }
    var isMax: Bool { if case .fixed(let r) = current, let max = fan.max { return r.isInfinite || r >= max } else { return false } }
    var isCustom: Bool { current != .auto && !isMax }

    var body: some View {
        HStack(spacing: 4) {
            Text(tr("Requested policy")).font(.system(size: 10)).foregroundStyle(.secondary)
            option(tr("Auto"), on: monitor.policiesAvailable && current == .auto) { monitor.setPolicy(.auto, fan: fan.id) }
            option(tr("Max"), on: monitor.policiesAvailable && isMax) { monitor.setPolicy(.fixed(rpm: .infinity), fan: fan.id) }.disabled(fan.validRange == nil)
            if monitor.policiesAvailable && isCustom {
                option(tr("Custom"), on: true) { MainWindow.show(.fans) }
            }
        }
    }

    func option(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption.weight(on ? .semibold : .regular))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(on ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.15)))
                .foregroundStyle(on ? Color.white : Color.primary)
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
                            .font(.callout)
                        }
                    }
                }
                Divider()
                ForEach(s.fans) { f in
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
            Image(systemName: "fan").foregroundStyle(fan.manual == true ? .orange : .secondary)
            Text(fan.name).frame(width: 52, alignment: .leading)
            FanLoadIndicator(fan: fan)
            Text(tr("%1$@ rpm", FanControlPresentation.rpm(fan.rpm))).monospacedDigit().frame(width: 76, alignment: .trailing)
        }
        .font(.callout)
        .help(tr("%1$@–%2$@ rpm · %3$@", FanControlPresentation.rpm(fan.min), FanControlPresentation.rpm(fan.max), tr(fan.controlMode)))
    }
}

struct BatteryRow: View {
    let battery: BatteryInfo
    let fahrenheit: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: battery.charging ? "battery.100.bolt" : "battery.75").foregroundStyle(.secondary)
            if let p = battery.percent { Text(String(format: "%.0f%%", p)) }
            if let t = battery.temperature { Text(tempText(t, fahrenheit: fahrenheit)).foregroundStyle(heatColor(t)) }
            if let w = battery.power { Text(String(format: "%+.1f W", w)) }
            Spacer()
            if let h = battery.health { Text(tr("health %1$@%%", String(format: "%.0f", h * 100))).foregroundStyle(.secondary) }
            if let c = battery.cycleCount { Text(tr("%1$@ cycles", String(c))).foregroundStyle(.secondary) }
        }
        .font(.caption)
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
                Text(tr("Waiting for temperature readings…")).font(.caption).foregroundStyle(.secondary)
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
            ForEach(rows) { r in row(r.name, key: r.key, value: String(format: f, r.value), color: .primary) }
        }
    }

    func section(_ t: String) -> some View {
        Text(t).font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 6)
    }

    func row(_ name: String, key: String, value: String, color: Color) -> some View {
        HStack {
            Text(name)
            Spacer()
            if !key.hasPrefix("hid:") { Text(key).font(.caption.monospaced()).foregroundStyle(.tertiary) }
            Text(value).monospacedDigit().foregroundStyle(color).frame(width: 70, alignment: .trailing)
        }
        .font(.callout)
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

/// The Fans page: one inspector panel per fan with its controls, then the speed history.
struct FansView: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            helperBanner
            if let s = monitor.snapshot {
                if s.fans.isEmpty {
                    InspectorPanel {
                        Label(tr("This Mac has no fans."), systemImage: "fan")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).padding(16)
                    }
                }
                ForEach(s.fans) { f in
                    // Always usable: without a helper, Apply queues the setting and starts setup.
                    FanControlCard(fan: f, policy: monitor.pendingPolicies[f.id] ?? monitor.policies[f.id] ?? .auto,
                                   enabled: !monitor.helperBusy, pending: monitor.pendingPolicies[f.id] != nil,
                                   policyAvailable: monitor.policiesAvailable, applying: monitor.applyingPolicies,
                                   controlState: monitor.fanControlState) { monitor.setPolicy($0, fan: f.id) }
                }
                if s.fans.count > 1 && [.running, .outdated].contains(monitor.helperState) {
                    Button(tr("All fans to Auto")) { monitor.setPolicy(.auto, fan: -1) }.disabled(monitor.helperBusy)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: tr("Fan speed, last 10 minutes"))
                InspectorPanel { FanChart(history: monitor.history).padding(14) }
            }
            Text(tr("Safety: sustained heat above %1$@ °C (%2$@ °C on Apple Silicon) pauses policies that reduce cooling. Full-speed cooling can continue. The helper attempts Auto on stopping; recovery failures are reported.",
                    String(Int(SafetyLimits.intel.ceiling)), String(Int(SafetyLimits.appleSilicon.ceiling))))
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        }
        .onAppear { monitor.refreshHelper() }
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
            notice(tr("Updating the system helper…"), tr("Recovery and helper startup must finish before controls become available."))
        case .notRunning:
            setupCard(icon: "exclamationmark.triangle", title: tr("Could not connect to the system helper"),
                      body: tr("Check the connection again, or reinstall the helper. macOS may ask for an administrator password."),
                      primary: (tr("Retry"), { monitor.refreshHelper() }),
                      secondary: (tr("Reinstall…"), { monitor.beginSetup() }))
        case .unknown:
            notice(tr("Checking the system helper…"), tr("Reading the helper’s status. You can keep viewing sensor readings."))
        case .notInstalled, .needsApproval:
            setupCard(icon: "fan", title: tr("Let Thermo control the fans"),
                      body: tr("Thermo's system helper manages fans, lid-closed wake, network low latency and charging protection. Fan requests stay within device ranges and recovery failures are reported. macOS may ask for an administrator password."),
                      primary: (tr("Allow…"), { monitor.beginSetup() }))
        }
        }
    }

    func notice(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            NoticeBanner(text: title + " " + body + (monitor.settingUp && !monitor.uninstallingHelper ? " " + tr("Setting up…") : ""), busy: true)
            pendingNote
        }
    }

    @ViewBuilder var pendingNote: some View {
        if !monitor.pendingPolicies.isEmpty {
            Text(tr("Your fan setting is applied as soon as the helper is ready."))
                .font(.system(size: 11)).foregroundStyle(.orange).padding(.horizontal, 4)
        }
    }

    func setupCard(icon: String, title: String, body: String, primary: (String, () -> Void)?, secondary: (String, () -> Void)? = nil) -> some View {
        InspectorPanel {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(.white.opacity(0.55))
                    .frame(width: 18).padding(.top, 1).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Text(body).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
                    if !monitor.pendingPolicies.isEmpty {
                        Text(tr("Your fan setting is applied as soon as the helper is ready."))
                            .font(.system(size: 11)).foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            if !renderingPreview {
                InspectorDivider(inset: 14)
                HStack(spacing: 8) {
                    if monitor.settingUp || monitor.uninstallingHelper {
                        ProgressView().controlSize(.small)
                        Text(tr(monitor.uninstallingHelper ? "Uninstalling…" : "Setting up…")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer()
                    if let secondary {
                        Button(secondary.0, action: secondary.1).controlSize(.small).disabled(monitor.settingUp || monitor.helperBusy)
                    }
                    if let primary {
                        Button(primary.0, action: primary.1).controlSize(.small)
                            .modifier(ActionButtonStyle(prominent: true)).disabled(monitor.settingUp || monitor.helperBusy)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
            }
        }
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
    let apply: (FanPolicy) -> Void

    @State private var mode: FanMode = .auto
    @State private var rpm: Double = 0
    @State private var preset: CurvePreset = .balanced
    @State private var customCurve = "50:min,70:3000,85:max"
    @State private var sensor: CurveSensor = .cpu
    @State private var curveError: String?

    var body: some View {
        InspectorPanel {
            header
            InspectorDivider(inset: 14)
            VStack(alignment: .leading, spacing: 8) {
                Picker(tr("Mode"), selection: $mode) { ForEach(FanMode.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented)
                    .labelsHidden().accessibilityLabel(tr("Mode"))
                    .disabled(!enabled)
                switch mode {
                case .auto:
                    EmptyView()
                case .fixed:
                    if let range = fan.validRange {
                    HStack {
                        Slider(value: $rpm, in: range.min...max(range.max, range.min + 1), step: 100).accessibilityLabel(tr("Fan speed"))
                        Text(tr("%1$@ rpm", String(format: "%.0f", rpm))).font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.9)).frame(width: 76, alignment: .trailing)
                    }
                    }
                case .curve:
                    HStack {
                        Picker(tr("Preset"), selection: $preset) { ForEach(CurvePreset.allCases) { Text($0.title).tag($0) } }
                        Picker(tr("Sensor"), selection: $sensor) { ForEach(CurveSensor.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) } }
                            .frame(width: 130)
                    }
                    if preset == .custom {
                        TextField("TEMP:RPM,…", text: $customCurve).textFieldStyle(.roundedBorder).font(.callout.monospaced())
                            .accessibilityLabel(tr("Custom fan curve"))
                            .onChange(of: customCurve) { _ in curveError = nil }
                        Text(tr("Curve temperatures use °C. RPM is limited to this fan’s range."))
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                    } else if let c = preset.curve {
                        Text(c.points.map { "\(Int($0.temperature))°C→\($0.rpm.isInfinite ? "max" : $0.rpm == 0 ? "min" : String(Int($0.rpm)))" }.joined(separator: "  "))
                            .font(.system(size: 11).monospaced()).foregroundStyle(.white.opacity(0.55))
                    }
                    if let curveError { Text(curveError).font(.system(size: 11)).foregroundStyle(.red) }
                }
                if mode != .auto && fan.validRange == nil { Text(tr("Fan range unavailable")).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            InspectorDivider(inset: 14)
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(pending ? tr("Waiting for helper: %1$@", policyText) : policyAvailable ? tr("Requested policy: %1$@", policyText) : tr("Requested policy unavailable"))
                    Text(FanControlPresentation.observation(controlState, fan: fan.id))
                    if let checked = controlState?.observations[fan.id]?.checkedAt, checked.timeIntervalSince1970.isFinite {
                        Text(tr("Checked at %1$@", checked.formatted(date: .numeric, time: .standard)))
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(applying ? tr("Sending…") : tr("Apply")) { applyCurrent() }.controlSize(.small).disabled(!enabled || (mode != .auto && fan.validRange == nil))
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
        }
        .disabled(!enabled)
        .onAppear(perform: load)
        // The helper's policies arrive after the card appears (at launch, after a helper restart):
        // Load the desired policy so Apply does not resend stale editor defaults.
        .onChange(of: policy) { _ in load() }
    }

    /// Name, live speed and range on one line, with a thin load bar under it.
    var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "fan").font(.system(size: 13)).foregroundStyle(fan.manual == true ? Color.orange : .white.opacity(0.55))
                    .frame(width: 18).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(fan.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Text(tr("%1$@–%2$@ rpm · %3$@", FanControlPresentation.rpm(fan.min), FanControlPresentation.rpm(fan.max), tr(fan.controlMode)))
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).monospacedDigit()
                }
                Spacer(minLength: 8)
                Text(tr("%1$@ rpm", FanControlPresentation.rpm(fan.rpm)))
                    .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(.white)
            }
            FanLoadIndicator(fan: fan)
                .padding(.leading, 28).accessibilityHidden(true)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    var policyText: String {
        switch policy {
        case .auto: return tr("Auto")
        case .fixed(let r): return r == .infinity ? tr("Max") : tr("%1$@ rpm", String(format: "%.0f", r))
        case .curve(let curve): return tr("Curve") + " · " + curve.pointsText + " (" + curve.sensor.rawValue.uppercased() + ")"
        }
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
        Chart {
            ForEach(FanChartSample.samples(history)) { p in
                LineMark(x: .value("Time", p.time), y: .value("RPM", p.rpm), series: .value("Segment", "\(p.fan):\(p.segment)"))
                    .foregroundStyle(by: .value("Fan", "Fan \(p.fan + 1)"))
            }
        }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute()) } }
        .chartLegend(position: .top, alignment: .trailing)
        .frame(height: 90)
    }
}

struct FanLoadIndicator: View {
    let fan: FanReading
    var body: some View {
        if let load = fan.load {
            Bar(value: load, color: fan.manual == nil ? .gray : fan.manual == true ? .orange : .blue)
        } else {
            Color.secondary.opacity(0.1).frame(height: 3).accessibilityLabel(tr("unknown"))
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
    @AppStorage(Settings.titleMetric) private var titleMetric = TitleMetric.cpu.rawValue
    @AppStorage(Settings.interval) private var interval = 2.0
    @AppStorage(Settings.alertsEnabled) private var alertsEnabled = false
    @AppStorage(Settings.alertThreshold) private var alertThreshold = 90.0
    @AppStorage(Settings.fahrenheit) private var fahrenheit = false
    @AppStorage(L10n.defaultsKey) private var language = "system"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            section(tr("Disk Cleanup")) {
                CleanupProtectionsButton(disk: disk)
            }
            section(tr("Clean Screen")) {
                CleanScreenButton()
            }
            section(tr("Network low latency")) { AWDLButton() }
            section(tr("Battery charging protection")) { BatteryCareButton() }
            section(tr("General")) {
                row(tr("Language")) {
                    Picker("", selection: $language) {
                        Text(tr("System")).tag("system")
                        ForEach(Language.allCases) { Text($0.displayName).tag($0.rawValue) }
                    }
                    .onChange(of: language) { L10n.apply(preference: $0) }
                }
                row(tr("Menu bar shows")) {
                    Picker("", selection: $titleMetric) { ForEach(TitleMetric.allCases) { Text($0.label).tag($0.rawValue) } }
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
                VStack(alignment: .leading, spacing: 10) {
                    if loginItem.state == .needsApproval {
                        Label(tr("Launch at login is waiting for macOS approval."), systemImage: "hourglass")
                        Button(tr("Open Login Items settings")) { loginItem.openSettings() }
                    } else if loginItem.state == .unavailable {
                        Label(tr("macOS could not find Thermo’s login item. Open the installed app and try again."), systemImage: "exclamationmark.triangle")
                    }
                    if let error = loginItem.error {
                        Text(error).foregroundStyle(.orange).textSelection(.enabled)
                    }
                }
                .font(.callout).foregroundStyle(.white.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .leading).padding(14).glass(radius: 12)
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
                AgentAccessRow().padding(14)
            }
            section(tr("System helper")) {
                row(tr("System helper: %1$@", helperText), last: true, labelControl: false) {
                    if [.running, .notRunning, .needsApproval, .outdated].contains(monitor.helperState) {
                        HStack(spacing: 8) {
                            if monitor.uninstallingHelper {
                                ProgressView().controlSize(.small)
                                Text(tr("Uninstalling…")).font(.caption)
                            }
                            Button(tr("Uninstall")) { monitor.uninstallHelper() }
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
                row("Thermo \(AppInfo.version)", last: true, labelControl: false) {
                    HStack {
                        if updates.enabled {
                            Button(tr("Check for Updates…")) { updates.checkForUpdates() }
                                .disabled(!updates.canCheck)
                                .help(updates.canCheck ? tr("Checks for a newer version of Thermo.") : tr("An update check is temporarily unavailable."))
                        }
                        Button(tr("Quit Thermo")) { NSApp.terminate(nil) }
                    }
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
        VStack(alignment: .leading, spacing: 10) {
            switch notifications.state {
            case .unknown:
                Label(tr("Checking notification permission…"), systemImage: "hourglass")
            case .unavailable:
                Label(tr("Notifications require an app bundle."), systemImage: "bell.slash")
            case .notRequested:
                Label(tr("Notification permission has not been requested."), systemImage: "bell.badge")
                Button(tr("Allow notifications")) { notifications.request() }.disabled(notifications.requesting)
            case .denied:
                Label(tr("Notifications are disabled in macOS."), systemImage: "bell.slash")
                Button(tr("Open notification settings")) { notifications.openSettings() }
            case .bannersDisabled:
                Label(tr("Notifications are authorized, but banners are disabled."), systemImage: "bell")
                Button(tr("Open notification settings")) { notifications.openSettings() }
            case .allowed:
                Label(tr("macOS has authorized notifications."), systemImage: "checkmark.circle")
            }
            if let error = notifications.error {
                Text(error).foregroundStyle(.orange).textSelection(.enabled)
            }
            if notifications.requesting { ProgressView().controlSize(.small) }
        }
        .font(.callout).foregroundStyle(.white.opacity(0.8)).frame(maxWidth: .infinity, alignment: .leading)
        .padding(14).glass(radius: 12)
    }

    func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.6)).padding(.leading, 4)
            VStack(spacing: 0) { content() }.glass(radius: 14)
        }
    }

    func row<C: View>(_ title: String, last: Bool = false, labelControl: Bool = true, @ViewBuilder _ control: () -> C) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 13)).foregroundStyle(.white.opacity(0.9))
                Spacer()
                if labelControl {
                    control().labelsHidden().fixedSize().accessibilityLabel(title)
                } else {
                    control().labelsHidden().fixedSize()
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            if !last { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.leading, 16) }
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
