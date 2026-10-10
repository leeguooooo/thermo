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
    @AppStorage(Settings.fahrenheit) private var fahrenheit = false
    @AppStorage(L10n.defaultsKey) private var language = "system"

    var body: some View {
        let _ = L10n.apply(preference: language)
        content.id(language)  // rebuild every string in the new language
    }

    var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if monitor.iconHidden {
                // The menu bar icon is behind the notch; say how to get it back.
                Label(tr("The menu bar icon is hidden behind the notch. Hold ⌘ and drag other icons out of the menu bar to make room, or open Thermo from the Dock."),
                      systemImage: "eye.slash")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .onTapGesture { monitor.iconHidden = false }
            }
            OverviewView(monitor: monitor)
            if let err = monitor.lastError {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(3)
                    .onTapGesture { monitor.lastError = nil }
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 380)
    }

    var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(tempText(monitor.snapshot?.maximumKnownTemperature, fahrenheit: fahrenheit))
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(heatColor(monitor.snapshot?.maximumKnownTemperature))
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Hottest")).font(.caption).foregroundStyle(.secondary)
                Text(monitor.model).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if let w = monitor.snapshot?.systemPower {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.1f W", w)).font(.title3.monospacedDigit())
                    Text(tr("System")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Into the main window: the whole app, or straight to a place in it.
    @ViewBuilder var footer: some View {
        if renderingPreview {
            // ImageRenderer cannot draw AppKit buttons; a look-alike for the preview.
            HStack(spacing: 12) {
                Label(tr("Open Console"), systemImage: "macwindow").font(.callout).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4).background(Capsule().fill(Color.accentColor))
                Spacer()
                ForEach(["internaldrive", "stethoscope", "rectangle.stack", "gearshape", "power"], id: \.self) {
                    Image(systemName: $0).foregroundStyle(.secondary)
                }
            }
        } else {
            liveFooter
        }
    }

    var liveFooter: some View {
        HStack(spacing: 6) {
            Button { MainWindow.show(.overview) } label: {
                Label(tr("Open Console"), systemImage: "macwindow")
            }
            .buttonStyle(.borderedProminent)
            Spacer()
            shortcut("internaldrive", tr("Disk Cleanup"), .disk(.home))
            shortcut("stethoscope", tr("AI Agent Diagnostics"), .agents(.home))
            shortcut("rectangle.stack", tr("Browser pages"), .browser("Google Chrome"))
            shortcut("gearshape", tr("Settings"), .settings)
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.borderless).help(tr("Quit Thermo"))
        }
        .controlSize(.regular)
    }

    func shortcut(_ symbol: String, _ title: String, _ page: MainPage) -> some View {
        Button { MainWindow.show(page) } label: { Image(systemName: symbol).frame(width: 22) }
            .buttonStyle(.borderless).help(title)
    }
}

/// Auto or full speed in one click; anything finer is in the main window's Fans page.
struct QuickFanSwitch: View {
    @ObservedObject var monitor: Monitor
    let fan: FanReading

    /// Read live from the helper's policies (never copied), so it always shows what is active.
    var current: FanPolicy { monitor.pendingPolicies[fan.id] ?? monitor.policies[fan.id] ?? .auto }
    var isMax: Bool { if case .fixed(let r) = current { return r.isInfinite || r >= fan.max } else { return false } }
    var isCustom: Bool { current != .auto && !isMax }

    var body: some View {
        HStack(spacing: 4) {
            option(tr("Auto"), on: monitor.policiesAvailable && current == .auto) { monitor.setPolicy(.auto, fan: fan.id) }
            option(tr("Max"), on: monitor.policiesAvailable && isMax) { monitor.setPolicy(.fixed(rpm: .infinity), fan: fan.id) }
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
            Image(systemName: "fan").foregroundStyle(fan.manual ? .orange : .secondary)
            Text(fan.name).frame(width: 52, alignment: .leading)
            Bar(value: fan.load, color: fan.manual ? .orange : .blue)
            Text(tr("%1$@ rpm", String(Int(fan.rpm)))).monospacedDigit().frame(width: 76, alignment: .trailing)
        }
        .font(.callout)
        .help(tr("%1$@–%2$@ rpm · %3$@", String(Int(fan.min)), String(Int(fan.max)), fan.manual ? tr("manual") : tr("auto")))
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

struct FansView: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            helperBanner
            if let s = monitor.snapshot {
                if s.fans.isEmpty {
                    Text(tr("This Mac has no fans.")).foregroundStyle(.secondary)
                }
                ForEach(s.fans) { f in
                    // Always usable: without a helper, Apply queues the setting and starts setup.
                    FanControlCard(fan: f, policy: monitor.pendingPolicies[f.id] ?? monitor.policies[f.id] ?? .auto,
                                   enabled: !monitor.helperBusy, pending: monitor.pendingPolicies[f.id] != nil,
                                   policyAvailable: monitor.policiesAvailable, applying: monitor.applyingPolicies) { monitor.setPolicy($0, fan: f.id) }
                }
                if s.fans.count > 1 && [.running, .outdated].contains(monitor.helperState) {
                    Button(tr("All fans to Auto")) { monitor.setPolicy(.auto, fan: -1) }.disabled(monitor.helperBusy)
                }
            }
            FanChart(history: monitor.history)
            Text(tr("Safety: fans go back to Auto while the CPU/GPU stays above %1$@ °C (%2$@ °C on Apple Silicon) and your settings resume once it cools down; also whenever the helper stops.",
                    String(Int(SafetyLimits.intel.ceiling)), String(Int(SafetyLimits.appleSilicon.ceiling))))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .onAppear { monitor.refreshHelper() }
    }

    /// Setup card: one button, one administrator password, done.
    @ViewBuilder var helperBanner: some View {
        if monitor.uninstallingHelper {
            setupCard(icon: "hourglass", title: tr("Uninstalling the fan helper…"),
                      body: tr("Fan controls are paused while the helper is removed. Sensor readings remain available."), primary: nil)
        } else {
        switch monitor.helperState {
        case .running:
            EmptyView()
        case .outdated:
            setupCard(icon: "arrow.triangle.2.circlepath", title: tr("Updating the fan helper…"),
                      body: tr("It switches to the new version by itself in a few seconds."), primary: nil)
        case .notRunning:
            setupCard(icon: "exclamationmark.triangle", title: tr("Could not connect to the fan helper"),
                      body: tr("Check the connection again, or reinstall the helper. macOS may ask for an administrator password."),
                      primary: (tr("Retry"), { monitor.refreshHelper() }),
                      secondary: (tr("Reinstall…"), { monitor.beginSetup() }))
        case .unknown:
            setupCard(icon: "hourglass", title: tr("Checking the fan helper…"),
                      body: tr("Reading the helper’s status. You can keep viewing sensor readings."), primary: nil)
        case .notInstalled, .needsApproval:
            setupCard(icon: "fan", title: tr("Let Thermo control the fans"),
                      body: tr("Fan control uses a small helper that runs with system rights. It only sets fan speeds within the fan's own limits, and hands the fans back to macOS when the helper stops or the Mac gets too hot. macOS asks for your password once; updates need nothing more."),
                      primary: (tr("Allow…"), { monitor.beginSetup() }))
        }
        }
    }

    func setupCard(icon: String, title: String, body: String, primary: (String, () -> Void)?, secondary: (String, () -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon).font(.title3).foregroundStyle(Color.accentColor).frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(body).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !monitor.pendingPolicies.isEmpty {
                        Text(tr("Your fan setting is applied as soon as the helper is ready."))
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            if !renderingPreview {
                HStack(spacing: 8) {
                    if monitor.settingUp || monitor.uninstallingHelper {
                        ProgressView().controlSize(.small)
                        Text(tr(monitor.uninstallingHelper ? "Uninstalling…" : "Setting up…")).font(.caption).foregroundStyle(.secondary)
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
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
    }
}

struct FanControlCard: View {
    let fan: FanReading
    let policy: FanPolicy
    let enabled: Bool
    var pending = false
    var policyAvailable = true
    var applying = false
    let apply: (FanPolicy) -> Void

    @State private var mode: FanMode = .auto
    @State private var rpm: Double = 0
    @State private var preset: CurvePreset = .balanced
    @State private var customCurve = "50:min,70:3000,85:max"
    @State private var sensor: CurveSensor = .cpu
    @State private var curveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FanRow(fan: fan)
            Picker(tr("Mode"), selection: $mode) { ForEach(FanMode.allCases) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented)
                .labelsHidden().accessibilityLabel(tr("Mode"))
                .disabled(!enabled)
            switch mode {
            case .auto:
                EmptyView()
            case .fixed:
                HStack {
                    Slider(value: $rpm, in: fan.min...max(fan.max, fan.min + 1), step: 100).accessibilityLabel(tr("Fan speed"))
                    Text(tr("%1$@ rpm", String(Int(rpm)))).monospacedDigit().frame(width: 76, alignment: .trailing)
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
                        .font(.caption).foregroundStyle(.secondary)
                } else if let c = preset.curve {
                    Text(c.points.map { "\(Int($0.temperature))°C→\($0.rpm.isInfinite ? "max" : $0.rpm == 0 ? "min" : String(Int($0.rpm)))" }.joined(separator: "  "))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                if let curveError { Text(curveError).font(.caption).foregroundStyle(.red) }
            }
            HStack {
                Text(pending ? tr("Waiting for helper: %1$@", policyText) : policyAvailable ? tr("Active: %1$@", policyText) : tr("Active policy unavailable")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button(applying ? tr("Applying…") : tr("Apply")) { applyCurrent() }.disabled(!enabled)
            }
        }
        .disabled(!enabled)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
        .onAppear(perform: load)
        // The helper's policies arrive after the card appears (at launch, after a helper restart):
        // show what is really active, or Apply would send the stale Auto the card started with.
        .onChange(of: policy) { _ in load() }
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
        rpm = min(fan.max, max(fan.min, fan.target ?? fan.rpm))
        switch policy {
        case .auto: mode = .auto
        case .fixed(let r): mode = .fixed; rpm = r.isInfinite ? fan.max : min(fan.max, max(fan.min, r))
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
            ForEach(history) { p in
                ForEach(Array(p.fans.enumerated()), id: \.offset) { i, rpm in
                    LineMark(x: .value("Time", p.time), y: .value("RPM", rpm), series: .value("Fan", "Fan \(i + 1)"))
                        .foregroundStyle(by: .value("Fan", "Fan \(i + 1)"))
                }
            }
        }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute()) } }
        .chartLegend(position: .top, alignment: .trailing)
        .frame(height: 90)
    }
}

// MARK: - Settings

struct SettingsView: View {
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
            section(tr("Fan helper")) {
                row(tr("Fan helper: %1$@", helperText), last: true, labelControl: false) {
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
