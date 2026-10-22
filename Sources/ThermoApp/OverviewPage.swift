import AppKit
import CleanKit
import SwiftUI
import ThermoKit
import ThermoL10n

/// The window's front page, organised around one question: why is this Mac hot or slow, who is
/// behind it, and what can be done. A sentence that names the source, then the heat chain
/// (load → temperature → fans → thermal pressure) with the weak link marked, then the busiest
/// programs with their actions, the other resources in one strip, and the temperature trend.
struct OverviewPage: View {
    @ObservedObject var monitor: Monitor
    let open: (MainPage) -> Void
    @ObservedObject private var pulse = SystemPulse.shared
    @ObservedObject private var events = TimelineEvents.shared
    @AppStorage(Settings.fahrenheit) private var fahrenheit = false
    @Environment(\.windowSamplingActive) private var visible

    var body: some View {
        WindowPage(title: tr("Overview"), subtitle: monitor.model) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                hero(now: monitor.snapshot?.timestamp ?? Date())
                headline
                vitals
            }
            .onAppear { if visible { events.refreshJournal() } }
            .onChange(of: monitor.snapshot?.timestamp) { _ in if visible { events.refreshJournal() } }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionHeader(title: tr("What is using your Mac"))
                PulseCard(active: visible, plain: true, headline: false)
            }
        }
    }

    // MARK: Hero

    /// What Thermo is about, first: how hot the Mac is now, and the last 15 minutes behind it.
    func hero(now: Date) -> some View {
        let s = monitor.snapshot
        let hot = s?.hottest
        return InspectorPanel {
            HStack(alignment: .top, spacing: Theme.Space.xl) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(tr("Hottest")).font(Theme.label).foregroundStyle(Theme.textTertiary)
                    Text(tempText(hot, fahrenheit: fahrenheit)).font(Theme.figure(.hero))
                        .foregroundStyle(hot == nil ? Theme.textTertiary : heatColor(hot))
                        .contentTransition(.numericText())
                        .lineLimit(1).minimumScaleFactor(0.6)
                    if let s {
                        Text("CPU \(tempText(s.cpu, fahrenheit: fahrenheit)) · GPU \(tempText(s.gpu, fahrenheit: fahrenheit))")
                            .font(Theme.secondary.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                    }
                    if let change = trend(now: now) {
                        Label(change.text, systemImage: change.rising ? "arrow.up.right" : "arrow.down.right")
                            .font(Theme.caption.monospacedDigit())
                            .foregroundStyle(change.rising ? Theme.caution : Theme.good)
                            .padding(.top, Theme.Space.xs)
                    }
                    heatScale(hot).padding(.top, Theme.Space.m)
                    Spacer(minLength: 0)
                }
                .frame(width: 168, alignment: .leading)
                .accessibilityElement(children: .combine)
                Rectangle().fill(Theme.hairline).frame(width: 1)
                HeatTimeline(history: monitor.history, events: events.events, now: now)
                    .frame(maxWidth: .infinity)
            }
            .padding(Theme.Space.l)
        }
    }

    /// The hottest reading now against five minutes ago; nil while there is not enough history.
    func trend(now: Date) -> (text: String, rising: Bool)? {
        func hottest(_ p: HistoryPoint) -> Double? { [p.cpu, p.gpu].compactMap { $0 }.filter(\.isFinite).max() }
        let history = monitor.history
        guard let last = history.last, let latest = hottest(last),
              let earlier = history.last(where: { now.timeIntervalSince($0.time) >= 300 }).flatMap(hottest) else { return nil }
        let delta = latest - earlier
        guard abs(delta) >= 2 else { return nil }
        let degrees = (fahrenheit ? delta * 9 / 5 : delta)
        return (tr("%1$@ in 5 min", String(format: "%+.0f°", degrees)), delta > 0)
    }

    /// Where the reading sits on the heat scale: the same green → red every temperature uses.
    func heatScale(_ hot: Double?) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(LinearGradient(colors: [heatColor(40), heatColor(70), heatColor(85), heatColor(100)],
                                              startPoint: .leading, endPoint: .trailing)).opacity(0.75)
                    .frame(height: 4)
                if let hot {
                    Circle().fill(Theme.textPrimary).frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(Theme.canvas, lineWidth: 2))
                        .offset(x: max(0, min(g.size.width - 9, g.size.width * CGFloat((hot - 30) / 80) - 4.5)))
                }
            }
            .frame(height: 9)
        }
        .frame(height: 9)
        .accessibilityHidden(true)
    }

    // MARK: Headline

    var severityColor: Color {
        guard pulse.current != nil else { return Theme.textTertiary }
        if pulse.severity == .green { return Theme.good }
        if pulse.severity == .red { return Theme.danger }
        return Theme.caution
    }

    /// The verdict and, when one source explains it, who that source is: one sentence in bold,
    /// the rest quieter under it.
    var headline: some View {
        let current = pulse.current
        return HStack(alignment: .top, spacing: Theme.Space.m) {
            ZStack {
                Circle().fill(severityColor.opacity(0.16))
                Image(systemName: current == nil ? "hourglass" : pulse.severity == .green ? "checkmark" : "exclamationmark")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(severityColor)
            }
            .frame(width: 28, height: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(current == nil ? tr("Checking what your Mac is busy with…") : pulse.verdict)
                    .font(Theme.heading).foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let current, let source = Self.sourceText(current) ?? current.culpritText {
                    Text(source).font(Theme.secondary).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let next = current?.nextStep {
                    Label(next.text, systemImage: "arrow.turn.down.right").font(Theme.secondary).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(severityColor.opacity(current == nil ? 0.04 : 0.07)))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(severityColor.opacity(0.22)))
        .animation(Theme.gentle, value: pulse.severity)
        .accessibilityElement(children: .combine)
    }

    /// Current directory and agent associations, not a causal attribution of system load.
    static func sourceText(_ p: MachinePulse) -> String? {
        // Capacity and pressure facts must not be replaced by project metadata.
        switch p.verdict { case .hot, .disk: return nil; default: break }
        guard !p.memory.isHigh else { return nil }
        let observed = p.hogs.filter { $0.cpu.isFinite && $0.cpu >= 0 }
        let groups = Dictionary(grouping: observed) { h -> String in
            guard let project = h.project, h.app == nil else { return "program|" + h.id }
            return "project|" + (h.owner ?? "") + "|" + project
        }.values
        guard let top = groups.max(by: { cpu($0) < cpu($1) }), let first = top.first, let project = first.project, first.app == nil else { return nil }
        let total = cpu(top)
        // This is observed CPU work, not a fraction of the one-minute load average.
        guard total >= 50 else { return nil }
        let folder = (project as NSString).lastPathComponent
        let names = top.sorted { $0.cpu > $1.cpu }.prefix(3).map(\.name).joined(separator: ", ")
        let cores = String(format: "%.1f", total / 100)
        if let owner = first.owner {
            return tr("Current sample: %3$@ in %1$@ (associated with %2$@), about %4$@ logical CPUs.", folder, owner, names, cores)
        }
        return tr("Current sample: %2$@ in %1$@, about %3$@ logical CPUs.", folder, names, cores)
    }

    static func cpu(_ hogs: [MachinePulse.Hog]) -> Double { hogs.reduce(0) { $0 + $1.cpu } }

    // MARK: Heat chain

    enum LinkState { case unknown, normal, watch, alert
        var color: Color {
            switch self {
            case .unknown: return Theme.textTertiary
            case .normal: return Theme.good
            case .watch: return Theme.caution
            case .alert: return Theme.danger
            }
        }
        /// The figure stays white while all is well; it takes the color only when it needs a look.
        var valueColor: Color { self == .watch || self == .alert ? color : Theme.textPrimary }
    }

    /// The heat chain (load → fans → thermal pressure; temperature is the hero above it) on top and the other
    /// resources under it, in one panel: one place to read the Mac's vitals.
    var vitals: some View {
        InspectorPanel {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    // Temperature leads the page above, so the chain here starts at load and ends at pressure.
                    loadLink; connector
                    fanLink; connector
                    pressureLink
                }
                .frame(minWidth: 480)
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow { loadLink; fanLink }
                    GridRow { pressureLink }
                }
            }
            InspectorDivider(inset: 0)
            resources
        }
    }

    /// The step between two links of the chain: a hairline with an arrow through it.
    var connector: some View {
        ZStack {
            Rectangle().fill(Theme.hairline).frame(width: 1)
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .heavy)).foregroundStyle(Theme.textTertiary)
                .frame(width: 14, height: 14)
                .background(Circle().fill(Theme.canvas))
                .overlay(Circle().strokeBorder(Theme.hairline))
        }
        .frame(width: 1).accessibilityHidden(true)
    }

    var loadLink: some View {
        let busy = pulse.current?.busy
        let state: LinkState = busy.map { $0 >= 2 ? .alert : $0 >= 1 ? .watch : .normal } ?? .unknown
        return link(tr("Load"), "cpu", value: busy.map { String(format: "%.1f×", $0) } ?? "—", caption: tr("load per core"),
                    detail: pulse.current.map { tr("%1$@ cores", String($0.cores)) + " · " + tr("load %1$@", String(format: "%.1f", $0.load1)) },
                    state: state) { open(.compute(false)) }
    }

    var temperatureLink: some View {
        let s = monitor.snapshot
        let hot = s?.hottest
        let state: LinkState = hot.map { $0 >= 85 ? .alert : $0 >= 65 ? .watch : .normal } ?? .unknown
        return link(tr("Temperature"), "thermometer.medium", value: tempText(hot, fahrenheit: fahrenheit), caption: tr("hottest"),
                    detail: s.map { "CPU \(tempText($0.cpu, fahrenheit: fahrenheit)) · GPU \(tempText($0.gpu, fahrenheit: fahrenheit))" },
                    state: state) { open(.sensors) }
    }

    /// Hot with the fans still well below their top speed is the one link worth pointing at here.
    var fanLink: some View {
        let s = monitor.snapshot
        let fans = monitor.sampledFans ?? []
        let top = fans.filter { $0.rpm != nil }.max { ($0.rpm ?? 0) < ($1.rpm ?? 0) }
        let hot = (s?.hottest ?? 0) >= 85
        let lagging = hot && fans.contains { $0.manual == false } && (fans.compactMap(\.load).max() ?? 1) < 0.6
        let state: LinkState = monitor.sampledFans == nil ? .unknown : fans.isEmpty || fans.contains { $0.manual == nil || $0.rpm == nil || $0.validRange == nil } ? .unknown : lagging ? .alert : .normal
        let mode = fans.contains { $0.manual == nil } ? tr("unknown") : fans.contains { $0.manual == true } ? tr("manual") : tr("auto")
        let detail: String? = monitor.sampledFans == nil ? monitor.fanEmptyMessage : fans.isEmpty ? tr("No fans")
            : lagging ? tr("Hot, but the fans are not at full speed")
            : top.map { mode + " · " + tr("%1$@ of max", $0.load.map { String(format: "%.0f%%", $0 * 100) } ?? tr("unknown")) }
        return link(tr("Fans"), "fan", value: FanControlPresentation.speedSummary(fans) ?? "—", caption: nil,
                    detail: detail, state: state, accessory: fans.isEmpty ? nil : AnyView(fanControls(fans))) { open(.fans) }
    }

    var pressureLink: some View {
        let thermal = pulse.current?.thermal
        let state: LinkState = thermal.map { $0 == .nominal ? .normal : $0 == .fair ? .watch : .alert } ?? .unknown
        let text: String
        switch thermal {
        case .none: text = "—"
        case .nominal: text = tr("normal")
        case .fair: text = tr("warm")
        case .serious: text = tr("hot, slowing down")
        case .critical: text = tr("critical, slowing down")
        }
        return link(tr("Thermal pressure"), "flame", value: text, caption: nil, detail: tr("Reported by macOS"),
                    state: state, compactValue: true) { open(.sensors) }
    }

    /// Auto or full speed for every fan, right where the fans are; finer control stays on the Fans page.
    @ViewBuilder func fanControls(_ fans: [FanReading]) -> some View {
        if monitor.policiesAvailable {
            let policies = fans.map { monitor.pendingPolicies[$0.id] ?? monitor.policies[$0.id] ?? .auto }
            let allAuto = policies.allSatisfy { $0 == .auto }
            let allMax = zip(fans, policies).allSatisfy { fan, policy in
                if case .fixed(let rpm) = policy { return fan.max.map { rpm.isInfinite || rpm >= $0 } ?? false } else { return false }
            }
            let canMax = !fans.contains { $0.validRange == nil }
            ThermoTabs(selection: Binding(get: { allAuto ? "auto" : allMax ? "max" : "" }, set: { value in
                if value == "auto" { fans.forEach { monitor.setPolicy(.auto, fan: $0.id) } }
                else if value == "max", canMax { fans.forEach { monitor.setPolicy(.fixed(rpm: .infinity), fan: $0.id) } }
            }), options: [("auto", tr("Auto")), ("max", tr("Max"))], size: .small, label: tr("Requested policy"))
            .disabled(monitor.helperBusy)
        } else {
            Button(tr("Fan settings…")) { open(.fans) }
                .buttonStyle(.plain).font(Theme.label).foregroundStyle(Theme.accent)
        }
    }

    func link(_ title: String, _ symbol: String, value: String, caption: String?, detail: String?, state: LinkState,
              compactValue: Bool = false, accessory: AnyView? = nil, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Button(action: action) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    HStack(spacing: 5) {
                        Image(systemName: symbol).font(.system(size: 11, weight: .medium)).accessibilityHidden(true)
                        Text(title).font(Theme.label)
                        if state == .watch || state == .alert {
                            Circle().fill(state.color).frame(width: 6, height: 6).accessibilityHidden(true)
                        }
                    }
                    .foregroundStyle(Theme.textTertiary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(value).font(Theme.figure(compactValue ? .large : .metric))
                            .foregroundStyle(state.valueColor).lineLimit(1).minimumScaleFactor(0.7)
                            .contentTransition(.numericText())
                        if let caption {
                            Text(caption).font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                        }
                    }
                    .frame(minHeight: 30, alignment: .bottomLeading)
                    Text(detail ?? " ").font(Theme.caption).foregroundStyle(state == .alert ? Theme.caution : Theme.textSecondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(tr("Open details"))
            if let accessory { accessory }
        }
        .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .hoverHighlight()
        .animation(Theme.gentle, value: state)
    }

    // MARK: Other resources

    /// Memory, disk, power and battery: worth a glance, not the story, so one compact strip.
    var resources: some View {
        let s = monitor.snapshot
        let mem = monitor.systemMemory
        let disk = monitor.systemDisk
        let cells: [(String, String, String?, MainPage)] = [
            (tr("Memory"), mem.map { String(format: "%.0f%%", Double($0.usedBytes) / Double(max(1, $0.totalBytes)) * 100) } ?? "—",
             [pulse.current.map { MachinePulse.memoryName($0.memory) },
              pulse.current.flatMap { $0.swapUsedMB > 0 ? tr("swap %1$@", MemoryFormat.string(mebibytes: $0.swapUsedMB)) : nil }]
                .compactMap { $0 }.joined(separator: " · "), .memory),
            (tr("Disk"), disk.map { ByteFormat.string($0.freeBytes) } ?? "—", tr("free"), .disk(.home)),
            (tr("Power"), s?.systemPower.map { String(format: "%.1f W", $0) } ?? "—", tr("System"), .sensors),
            (tr("Battery"), s?.battery?.percent.map { String(format: "%.0f%%", $0) } ?? "—",
             s?.battery.map { b in b.health.map { tr("health %1$@%%", String(format: "%.0f", $0 * 100)) } ?? (b.charging ? tr("charging") : "") },
             .sensors),
        ]
        let items = cells.filter { !($0.0 == tr("Battery") && s?.battery == nil) }
        return Group {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, cell in
                        if index > 0 { Rectangle().fill(Theme.hairline).frame(width: 1, height: 16).padding(.top, Theme.Space.m) }
                        resource(cell.0, cell.1, cell.2, cell.3)
                    }
                }
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { start in
                        GridRow {
                            resource(items[start].0, items[start].1, items[start].2, items[start].3)
                            if start + 1 < items.count { resource(items[start + 1].0, items[start + 1].1, items[start + 1].2, items[start + 1].3) }
                        }
                    }
                }
            }
        }
    }

    func resource(_ title: String, _ value: String, _ note: String?, _ page: MainPage) -> some View {
        Button { open(page) } label: {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(title).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                Text(value).font(Theme.figure(.row)).foregroundStyle(Theme.textPrimary).contentTransition(.numericText())
                Text(note?.isEmpty == false ? note! : "").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
            .contentShape(Rectangle())
            .hoverHighlight()
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}
