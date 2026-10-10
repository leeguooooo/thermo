import Charts
import SwiftUI
import ThermoKit
import ThermoL10n

// MARK: - Formatting

func tempText(_ c: Double?, fahrenheit: Bool) -> String {
    guard let c else { return "—" }
    return fahrenheit ? String(format: "%.0f°F", c * 9 / 5 + 32) : String(format: "%.0f°C", c)
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

enum Tab: String, CaseIterable, Identifiable {
    case overview = "Overview", sensors = "Sensors", fans = "Fans", disk = "Disk", agents = "Agents", settings = "Settings"
    var id: String { rawValue }
    var title: String { tr(rawValue) }

    /// Six tabs only fit at popover width with Settings as an icon.
    @ViewBuilder var label: some View {
        if self == .settings { Image(systemName: "gearshape").accessibilityLabel(title) } else { Text(title) }
    }
}

struct PopoverView: View {
    @ObservedObject var monitor: Monitor
    var updates: Updates
    @ObservedObject var disk: DiskModel
    @State var tab: Tab = .overview
    @StateObject var agents = AgentScanner()
    @AppStorage(Settings.fahrenheit) private var fahrenheit = false
    @AppStorage(L10n.defaultsKey) private var language = "system"

    var body: some View {
        content
            .id(language)  // rebuild every string in the new language
            .onChange(of: language) { _ in agents.scan() }  // diagnostics are worded at scan time
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
            if renderingPreview {
                // ImageRenderer cannot draw the AppKit segmented control; draw a look-alike.
                HStack(spacing: 2) {
                    ForEach(Tab.allCases) { t in
                        t.label.font(.callout).frame(maxWidth: t == .settings ? 28 : .infinity).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(t == tab ? Color(nsColor: .controlBackgroundColor) : .clear)
                                .shadow(color: .black.opacity(t == tab ? 0.15 : 0), radius: 1, y: 0.5))
                    }
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
            } else {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { $0.label.tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Group {
                switch tab {
                case .overview: OverviewView(monitor: monitor)
                case .sensors: SensorsView(monitor: monitor)
                case .fans: FansView(monitor: monitor)
                case .disk: DiskView(model: disk)
                case .agents: AgentsView(scanner: agents)
                case .settings: SettingsView(monitor: monitor, updates: updates)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            if let err = monitor.lastError {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(3)
                    .onTapGesture { monitor.lastError = nil }
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(tempText(monitor.snapshot?.hottest, fahrenheit: fahrenheit))
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(heatColor(monitor.snapshot?.hottest))
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
}

// MARK: - Overview

struct OverviewView: View {
    @ObservedObject var monitor: Monitor
    @AppStorage(Settings.fahrenheit) private var fahrenheit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PulseCard()
            if let s = monitor.snapshot {
                VStack(spacing: 6) {
                    ForEach(SensorGroup.allCases, id: \.self) { g in
                        if let t = s.maxTemperature(in: g) {
                            HStack {
                                Text(g.rawValue).frame(width: 70, alignment: .leading)
                                Bar(value: t / 100, color: heatColor(t))
                                Text(tempText(t, fahrenheit: fahrenheit)).monospacedDigit().frame(width: 52, alignment: .trailing)
                            }
                            .font(.callout)
                        }
                    }
                }
                Divider()
                ForEach(s.fans) { f in FanRow(fan: f) }
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
    var body: some View {
        Chart {
            ForEach(history) { p in
                if let c = p.cpu {
                    LineMark(x: .value("Time", p.time), y: .value("°C", c), series: .value("Sensor", "CPU"))
                        .foregroundStyle(by: .value("Sensor", "CPU"))
                }
                if let g = p.gpu {
                    LineMark(x: .value("Time", p.time), y: .value("°C", g), series: .value("Sensor", "GPU"))
                        .foregroundStyle(by: .value("Sensor", "GPU"))
                }
            }
        }
        .chartYScale(domain: 20...105)
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
    @AppStorage(Settings.fahrenheit) private var fahrenheit = false

    var body: some View {
        if renderingPreview { list } else { ScrollView { list }.frame(height: 360) }
    }

    var list: some View {
        Group {
            LazyVStack(alignment: .leading, spacing: 3) {
                if let s = monitor.snapshot {
                    ForEach(SensorGroup.allCases, id: \.self) { g in
                        let rows = s.temperatures.filter { $0.group == g }
                        if !rows.isEmpty {
                            section(g.rawValue)
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
                                   enabled: true) { monitor.setPolicy($0, fan: f.id) }
                }
                if s.fans.count > 1 && [.running, .outdated].contains(monitor.helperState) {
                    Button(tr("All fans to Auto")) { monitor.setPolicy(.auto, fan: -1) }
                }
            }
            FanChart(history: monitor.history)
            Text(tr("Safety: fans go back to Auto while the CPU/GPU stays above %1$@ °C (%2$@ °C on Apple Silicon) and your settings resume once it cools down; also whenever the helper stops.",
                    String(Int(SafetyLimits.intel.ceiling)), String(Int(SafetyLimits.appleSilicon.ceiling))))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .onAppear { monitor.refreshHelper() }
    }

    /// Setup card: one button to allow the helper, a live guide while the user is in System
    /// Settings, and the administrator-password route when Login Items approval is stuck.
    @ViewBuilder var helperBanner: some View {
        switch monitor.helperState {
        case .running:
            EmptyView()
        case .outdated:
            setupCard(icon: "arrow.triangle.2.circlepath", title: tr("The fan helper is from an older version"),
                      body: tr("Thermo restarts it on the new version; this takes a moment."),
                      primary: (tr("Update…"), { monitor.beginSetup() }))
        case .needsApproval:
            setupCard(icon: "lock.open", title: tr("Turn on Thermo in System Settings"),
                      body: tr("In Login Items & Extensions, under Allow in the Background, switch on Thermo. It may be grouped under its developer, LI GUO — click ⓘ to see it. Thermo carries on by itself as soon as it is on."),
                      primary: (tr("Open Settings"), { monitor.openLoginItemsSettings(); monitor.beginSetup() }),
                      waiting: true)
        case .notRunning:
            setupCard(icon: "exclamationmark.triangle", title: tr("The fan helper is not running"),
                      body: tr("macOS did not start it. Try again, or install it with your administrator password."),
                      primary: (tr("Try Again"), { monitor.beginSetup() }))
        case .notInstalled, .unknown:
            setupCard(icon: "fan", title: tr("Let Thermo control the fans"),
                      body: tr("Fan control uses a small helper that runs in the background with system rights. It only sets fan speeds within the fan's own limits, and hands the fans back to macOS when Thermo quits or the Mac gets too hot."),
                      primary: (tr("Allow…"), { monitor.beginSetup() }))
        }
    }

    func setupCard(icon: String, title: String, body: String, primary: (String, () -> Void), waiting: Bool = false) -> some View {
        let stuck = (monitor.setupStarted.map { Date().timeIntervalSince($0) > 8 } ?? false) || monitor.helperState == .notRunning
        return VStack(alignment: .leading, spacing: 8) {
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
                    if monitor.settingUp || waiting {
                        ProgressView().controlSize(.small)
                        Text(tr("Waiting for macOS…")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    // Login Items approval sometimes never takes; the password route always does.
                    if monitor.usesSMAppService && (stuck || waiting) {
                        Button(tr("Use Administrator Password")) { monitor.installHelperWithPassword() }
                            .controlSize(.small).modifier(ActionButtonStyle(prominent: false))
                    }
                    Button(primary.0, action: primary.1).controlSize(.small).modifier(ActionButtonStyle(prominent: true))
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
        // Refresh the "stuck" timing while setup runs.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if monitor.settingUp { monitor.objectWillChange.send() }
        }
    }
}

struct FanControlCard: View {
    let fan: FanReading
    let policy: FanPolicy
    let enabled: Bool
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
                .labelsHidden()
                .disabled(!enabled)
            switch mode {
            case .auto:
                EmptyView()
            case .fixed:
                HStack {
                    Slider(value: $rpm, in: fan.min...max(fan.max, fan.min + 1), step: 100)
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
                } else if let c = preset.curve {
                    Text(c.points.map { "\(Int($0.temperature))°→\($0.rpm.isInfinite ? "max" : $0.rpm == 0 ? "min" : String(Int($0.rpm)))" }.joined(separator: "  "))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                if let curveError { Text(curveError).font(.caption).foregroundStyle(.red) }
            }
            HStack {
                Text(tr("Active: %1$@", policy.description)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button(tr("Apply")) { applyCurrent() }.disabled(!enabled)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
        .onAppear(perform: load)
    }

    func load() {
        rpm = fan.target ?? fan.rpm
        switch policy {
        case .auto: mode = .auto
        case .fixed(let r): mode = .fixed; rpm = r.isInfinite ? fan.max : r
        case .curve(let c):
            mode = .curve
            sensor = c.sensor
            preset = CurvePreset.allCases.first { $0.curve?.points == c.points } ?? .custom
            if preset == .custom { customCurve = c.points.map { "\(Int($0.temperature)):\($0.rpm.isInfinite ? "max" : $0.rpm == 0 ? "min" : String(Int($0.rpm)))" }.joined(separator: ",") }
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
    @ObservedObject var updates: Updates
    @AppStorage(Settings.titleMetric) private var titleMetric = TitleMetric.cpu.rawValue
    @AppStorage(Settings.interval) private var interval = 2.0
    @AppStorage(Settings.alertsEnabled) private var alertsEnabled = false
    @AppStorage(Settings.alertThreshold) private var alertThreshold = 90.0
    @AppStorage(Settings.fahrenheit) private var fahrenheit = false
    @AppStorage(L10n.defaultsKey) private var language = "system"

    var body: some View {
        Form {
            Picker(tr("Language"), selection: $language) {
                Text(tr("System")).tag("system")
                ForEach(Language.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            .onChange(of: language) { L10n.apply(preference: $0) }
            Picker(tr("Menu bar shows"), selection: $titleMetric) {
                ForEach(TitleMetric.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Picker(tr("Update every"), selection: $interval) {
                Text("0.5 s").tag(0.5); Text("1 s").tag(1.0); Text("2 s").tag(2.0); Text("5 s").tag(5.0)
            }
            .onChange(of: interval) { _ in monitor.reschedule() }
            Toggle(tr("Fahrenheit"), isOn: $fahrenheit)
            Toggle(tr("Alert when hot"), isOn: $alertsEnabled)
                .onChange(of: alertsEnabled) { on in if on { Monitor.requestNotificationPermission() } }
            if alertsEnabled {
                Stepper(value: $alertThreshold, in: 60...105, step: 1) {
                    Text(tr("Threshold: %1$@ °C", String(Int(alertThreshold))))
                }
            }
            Toggle(tr("Show in Dock"), isOn: $showInDock)
            Toggle(tr("Launch at login"), isOn: Binding(get: { monitor.launchAtLogin }, set: { monitor.launchAtLogin = $0 }))
            HStack {
                Text(tr("Fan helper: %1$@", helperText)).foregroundStyle(.secondary)
                Spacer()
                if [.running, .notRunning, .needsApproval, .outdated].contains(monitor.helperState) {
                    Button(tr("Uninstall")) { monitor.uninstallHelper() }
                }
            }
            if updates.enabled {
                Toggle(tr("Check for updates automatically"), isOn: Binding(get: { updates.automaticallyChecks },
                                                                       set: { updates.automaticallyChecks = $0 }))
                Button(tr("Check for Updates…")) { updates.checkForUpdates() }
            }
            HStack {
                Text("Thermo \(AppInfo.version)").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button(tr("Quit Thermo")) { NSApp.terminate(nil) }
            }
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
