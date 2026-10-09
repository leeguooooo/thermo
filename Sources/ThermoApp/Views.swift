import Charts
import SwiftUI
import ThermoKit

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
    case overview = "Overview", sensors = "Sensors", fans = "Fans", settings = "Settings"
    var id: String { rawValue }
}

struct PopoverView: View {
    @ObservedObject var monitor: Monitor
    @State var tab: Tab = .overview
    @AppStorage(Settings.fahrenheit) private var fahrenheit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch tab {
                case .overview: OverviewView(monitor: monitor)
                case .sensors: SensorsView(monitor: monitor)
                case .fans: FansView(monitor: monitor)
                case .settings: SettingsView(monitor: monitor)
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
                Text("Hottest").font(.caption).foregroundStyle(.secondary)
                Text(monitor.model).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if let w = monitor.snapshot?.systemPower {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.1f W", w)).font(.title3.monospacedDigit())
                    Text("System").font(.caption).foregroundStyle(.secondary)
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
            Text("\(Int(fan.rpm)) rpm").monospacedDigit().frame(width: 76, alignment: .trailing)
        }
        .font(.callout)
        .help("\(Int(fan.min))–\(Int(fan.max)) rpm · \(fan.manual ? "manual" : "auto")")
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
            if let h = battery.health { Text(String(format: "health %.0f%%", h * 100)).foregroundStyle(.secondary) }
            if let c = battery.cycleCount { Text("\(c) cycles").foregroundStyle(.secondary) }
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
                    electrical("Power", s.power, "%.2f W")
                    electrical("Voltage", s.voltages, "%.3f V")
                    electrical("Current", s.currents, "%.3f A")
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
}

enum CurvePreset: String, CaseIterable, Identifiable {
    case quiet = "Quiet", balanced = "Balanced", performance = "Performance", custom = "Custom"
    var id: String { rawValue }
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
                    Text("This Mac has no fans.").foregroundStyle(.secondary)
                }
                ForEach(s.fans) { f in
                    FanControlCard(fan: f, policy: monitor.policies[f.id] ?? .auto,
                                   enabled: monitor.helperState == .running) { monitor.setPolicy($0, fan: f.id) }
                }
                if s.fans.count > 1 && monitor.helperState == .running {
                    Button("All fans to Auto") { monitor.setPolicy(.auto, fan: -1) }
                }
            }
            FanChart(history: monitor.history)
            Text("Safety: fans return to Auto if any CPU/GPU sensor reaches \(Int(FanPolicyEngine.safetyCeiling)) °C, or when the helper stops.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .onAppear { monitor.refreshHelper() }
    }

    @ViewBuilder var helperBanner: some View {
        switch monitor.helperState {
        case .running:
            EmptyView()
        case .notInstalled, .unknown:
            HStack {
                Text("Fan control needs a privileged helper.").font(.callout)
                Spacer()
                Button("Install…") { monitor.installHelper() }
            }
        case .needsApproval:
            HStack {
                Text("Allow Thermo's helper in System Settings → Login Items.").font(.callout)
                Spacer()
                Button("Open Settings") { monitor.openLoginItemsSettings() }
            }
            .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in monitor.refreshHelper() }
        case .notRunning:
            HStack {
                Text("Helper installed but not responding.").font(.callout)
                Spacer()
                Button("Reinstall…") { monitor.installHelper() }
            }
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
            Picker("Mode", selection: $mode) { ForEach(FanMode.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!enabled)
            switch mode {
            case .auto:
                EmptyView()
            case .fixed:
                HStack {
                    Slider(value: $rpm, in: fan.min...max(fan.max, fan.min + 1), step: 100)
                    Text("\(Int(rpm)) rpm").monospacedDigit().frame(width: 76, alignment: .trailing)
                }
            case .curve:
                HStack {
                    Picker("Preset", selection: $preset) { ForEach(CurvePreset.allCases) { Text($0.rawValue).tag($0) } }
                    Picker("Sensor", selection: $sensor) { ForEach(CurveSensor.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) } }
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
                Text("Active: \(policy.description)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Apply") { applyCurrent() }.disabled(!enabled)
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
    @AppStorage(Settings.titleMetric) private var titleMetric = TitleMetric.cpu.rawValue
    @AppStorage(Settings.interval) private var interval = 2.0
    @AppStorage(Settings.alertsEnabled) private var alertsEnabled = false
    @AppStorage(Settings.alertThreshold) private var alertThreshold = 90.0
    @AppStorage(Settings.fahrenheit) private var fahrenheit = false

    var body: some View {
        Form {
            Picker("Menu bar shows", selection: $titleMetric) {
                ForEach(TitleMetric.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Picker("Update every", selection: $interval) {
                Text("0.5 s").tag(0.5); Text("1 s").tag(1.0); Text("2 s").tag(2.0); Text("5 s").tag(5.0)
            }
            .onChange(of: interval) { _ in monitor.reschedule() }
            Toggle("Fahrenheit", isOn: $fahrenheit)
            Toggle("Alert when hot", isOn: $alertsEnabled)
                .onChange(of: alertsEnabled) { on in if on { Monitor.requestNotificationPermission() } }
            if alertsEnabled {
                Stepper(value: $alertThreshold, in: 60...105, step: 1) {
                    Text("Threshold: \(Int(alertThreshold)) °C")
                }
            }
            Toggle("Launch at login", isOn: Binding(get: { monitor.launchAtLogin }, set: { monitor.launchAtLogin = $0 }))
            HStack {
                Text("Fan helper: " + helperText).foregroundStyle(.secondary)
                Spacer()
                if [.running, .notRunning, .needsApproval].contains(monitor.helperState) {
                    Button("Uninstall") { monitor.uninstallHelper() }
                }
            }
            HStack {
                Text("thermo 1.0.0").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Quit Thermo") { NSApp.terminate(nil) }
            }
        }
    }

    var helperText: String {
        switch monitor.helperState {
        case .running: return "running"
        case .notRunning: return "not responding"
        case .notInstalled: return "not installed"
        case .needsApproval: return "waiting for approval"
        case .unknown: return "…"
        }
    }
}
