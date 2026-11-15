import SystemServicesAPI
import ThermoUI
import CleanKit
import Charts
import SwiftUI
import ThermoKit
import ThermoL10n

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

struct QuickFanSwitch: View {
    @ObservedObject var monitor: PerformanceModel
    let fan: FanReading
    let openFans: () -> Void

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
                option(tr("Custom"), on: true) { openFans() }
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


struct FanRow: View {
    let fan: FanReading
    var stopped = false
    var body: some View {
        HStack {
            Image(systemName: "fan").foregroundStyle(fan.manual == true ? Theme.caution : Theme.textSecondary)
            Text(fan.displayName).frame(width: 52, alignment: .leading)
            FanLoadIndicator(fan: fan)
            Text(tr("%1$@ rpm", FanControlPresentation.rpm(fan.reportedRPM(stopped: stopped ? [fan.id] : [])))).monospacedDigit().frame(width: 76, alignment: .trailing)
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


struct SensorsView: View {
    @ObservedObject var monitor: PerformanceModel
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
    @ObservedObject var monitor: PerformanceModel

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
        .onAppear { monitor.refreshFanObservation() }
    }

    func missingFan(_ id: Int) -> some View {
        let policy = FanPolicyText.label(monitor.pendingPolicies[id] ?? monitor.policies[id] ?? .auto)
        let checked = monitor.fanControlState?.observations[id]?.checkedAt
        let detail = [tr("No current reading for this fan. Saved settings and last checks are shown below."),
                      FanControlPresentation.observation(monitor.fanControlState, fan: id),
                      checked.flatMap { $0.timeIntervalSince1970.isFinite ? tr("Checked at %1$@", $0.text(date: .numeric, time: .standard)) : nil }]
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
                            FanFigure(fan: f, checking: monitor.helperState == .unknown, stopped: monitor.stoppedFans.contains(f.id))
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
    var stopped = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "fan").font(.system(size: 11, weight: .medium)).accessibilityHidden(true)
                Text(fan.displayName).font(Theme.label)
                if fan.manual == true { StatusTag(text: tr("manual"), color: Theme.caution) }
            }
            .foregroundStyle(Theme.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                if checking && (fan.rpm ?? 0) == 0 && !stopped {
                    // A zero while the helper is still being read says nothing yet.
                    Text("—").font(Theme.figure(.hero)).foregroundStyle(Theme.textTertiary)
                } else {
                    Text(FanControlPresentation.rpm(fan.reportedRPM(stopped: stopped ? [fan.id] : []))).font(Theme.figure(.hero)).foregroundStyle(Theme.textPrimary)
                        .contentTransition(.numericText())
                        .animation(Theme.standard.unlessReduced(reduceMotion), value: fan.rpm)
                }
                // The unit alone, from the same localized pattern the rest of the app uses.
                Text(tr("%1$@ rpm", "").trimmingCharacters(in: .whitespaces)).font(Theme.label).foregroundStyle(Theme.textTertiary)
            }
            FanLoadIndicator(fan: fan).frame(maxWidth: 220).accessibilityHidden(true)
            Text(tr("%1$@–%2$@ rpm · %3$@", FanControlPresentation.rpm(fan.min), FanControlPresentation.rpm(fan.max), tr(fan.controlMode)))
                .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
            if stopped && fan.rpm == 0 && fan.manual == false {
                Text(tr("Paused by macOS at the current temperature; it starts on its own when more cooling is needed."))
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
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
                        Text(fan.displayName).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary)
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
                    // Nothing to send while the editor matches the requested policy (unless restoring after a failure or
                    // a safety suspension), or while the helper is being checked.
                    .disabled(!enabled || checking || applying || (mode != .auto && fan.validRange == nil) || (unchanged && controlState?.failure == nil && controlState?.suspended != true))
            }
            .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s)
        }
        .disabled(!enabled)
        .onAppear { load(policy) }
        // The helper's policies arrive after the card appears (at launch, after a helper restart, after Apply):
        // load the new policy so Apply does not resend stale editor defaults. Use the value passed in —
        // `self.policy` inside this closure is still the previous one, which flipped the picker back to the old mode.
        .onChange(of: policy) { load($0) }
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
            HStack(spacing: Theme.Space.xs) {
                ProgressView().controlSize(.mini)
                Text(tr("Checking…")).font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
        } else {
            let checked = controlState?.observations[fan.id]?.checkedAt
            let detail = [FanControlPresentation.observation(controlState, fan: fan.id),
                          checked.flatMap { $0.timeIntervalSince1970.isFinite ? tr("Checked at %1$@", $0.text(date: .numeric, time: .standard)) : nil }]
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
        FanPolicyText.label(policy)
    }

    func load(_ policy: FanPolicy) {
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

    func isAuto(_ p: FanPolicy) -> Bool { if case .auto = p { return true } else { return false } }

    /// The editor shows exactly the requested policy, so Apply would resend it.
    var unchanged: Bool { Self.matches(mode: mode, rpm: rpm, curve: draftCurve, policy: policy, range: fan.validRange) }
    var draftCurve: FanCurve? {
        guard var c = try? (preset.curve ?? FanCurve(parsing: customCurve)) else { return nil }
        c.sensor = sensor
        return c
    }
    static func matches(mode: FanMode, rpm: Double, curve: FanCurve?, policy: FanPolicy, range: (min: Double, max: Double)?) -> Bool {
        switch (mode, policy) {
        case (.auto, .auto): return true
        case (.fixed, .fixed(let r)):
            guard let range else { return false }
            let requested = r.isInfinite ? range.max : min(range.max, max(range.min, r))
            return abs(requested - rpm) < 0.5
        case (.curve, .curve(let c)): return curve.map { $0.points == c.points && $0.sensor == c.sensor } ?? false
        default: return false
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
        let end = history.last?.time ?? Date()
        let samples = FanChartSample.samples(history.filter { $0.time >= end.addingTimeInterval(-600) })
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
        // Always the full ten minutes the title promises; a few seconds of data no longer repeats one minute on the axis.
        .chartXScale(domain: end.addingTimeInterval(-600)...end)
        // Marks inside the window: one at "now" or ten minutes back sits on an edge and gets clipped to "1…".
        .chartXAxis { AxisMarks(values: [9, 6, 3].map { end.addingTimeInterval(-Double($0) * 60) }) { _ in
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
