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

    var body: some View {
        WindowPage(title: tr("Overview"), subtitle: monitor.model) {
            TimelineView(.periodic(from: .now, by: 3)) { _ in
                VStack(alignment: .leading, spacing: 14) {
                    headline
                    chain
                    resources
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: tr("What is using your Mac"))
                InspectorPanel {
                    PulseCard(active: monitor.panelVisible, plain: true, headline: false).padding(.horizontal, 6).padding(.vertical, 4)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: tr("Last 15 minutes"))
                InspectorPanel {
                    TimelineView(.periodic(from: .now, by: 3)) { context in
                        HeatTimeline(history: monitor.history, events: events.events, now: context.date)
                            .onAppear { events.refreshJournal() }
                            .onChange(of: context.date) { _ in events.refreshJournal() }
                    }
                    .padding(14)
                }
            }
        }
    }

    // MARK: Headline

    /// The verdict and, when one source explains it, who that source is.
    var headline: some View {
        let current = pulse.current
        return InspectorPanel {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: current == nil ? "hourglass" : pulse.severity == .green ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 22)).foregroundStyle(current == nil ? Color.white.opacity(0.5) : pulse.severity)
                    .frame(width: 26).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(current == nil ? tr("Checking what your Mac is busy with…") : pulse.verdict)
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    if let current, let source = Self.sourceText(current) ?? current.culpritText {
                        Text(source).font(.system(size: 13)).foregroundStyle(.white.opacity(0.75))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let next = current?.nextStep {
                        Text(next.text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .accessibilityElement(children: .combine)
        }
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
            case .unknown: return .white.opacity(0.4)
            case .normal: return .green
            case .watch: return .orange
            case .alert: return .red
            }
        }
    }

    var chain: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: tr("Heat chain"))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    loadLink.frame(minWidth: 150); connector
                    temperatureLink.frame(minWidth: 150); connector
                    fanLink.frame(minWidth: 150); connector
                    pressureLink.frame(minWidth: 150)
                }
                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow { loadLink; temperatureLink }
                    GridRow { fanLink; pressureLink }
                }
            }
        }
    }

    var connector: some View {
        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.3))
            .frame(width: 18).accessibilityHidden(true)
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
            HStack(spacing: 4) {
                Text(tr("Requested policy")).font(.system(size: 10)).foregroundStyle(.secondary)
                fanOption(tr("Auto"), on: allAuto) { fans.forEach { monitor.setPolicy(.auto, fan: $0.id) } }
                fanOption(tr("Max"), on: allMax) { fans.forEach { monitor.setPolicy(.fixed(rpm: .infinity), fan: $0.id) } }.disabled(fans.contains { $0.validRange == nil })
            }
        } else {
            Button(tr("Fan settings…")) { open(.fans) }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
        }
    }

    func fanOption(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: on ? .semibold : .regular))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().fill(on ? Color.white.opacity(0.22) : Color.white.opacity(0.07)))
                .foregroundStyle(.white.opacity(on ? 1 : 0.7))
        }
        .buttonStyle(.plain).disabled(monitor.helperBusy)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    func link(_ title: String, _ symbol: String, value: String, caption: String?, detail: String?, state: LinkState,
              compactValue: Bool = false, accessory: AnyView? = nil, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).accessibilityHidden(true)
                        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                        Spacer(minLength: 4)
                        Circle().fill(state.color).frame(width: 7, height: 7).accessibilityHidden(true)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(value).font(.system(size: compactValue ? 15 : 22, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white).lineLimit(compactValue ? 2 : 1).minimumScaleFactor(0.8)
                            .fixedSize(horizontal: false, vertical: true)
                        if let caption {
                            Text(caption).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                        }
                    }
                    Text(detail ?? " ").font(.system(size: 11)).foregroundStyle(state == .alert ? Color.orange : .white.opacity(0.55))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(tr("Open details"))
            if let accessory { accessory }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(state == .alert ? 0.09 : 0.055)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(state == .alert || state == .watch ? state.color.opacity(0.55) : Color.white.opacity(0.09)))
    }

    // MARK: Other resources

    /// Memory, disk, power and battery: worth a glance, not the story, so one compact strip.
    var resources: some View {
        let s = monitor.snapshot
        let mem = SystemStats.memory()
        let disk = SystemStats.disk()
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
        return InspectorPanel {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, cell in
                        if index > 0 { Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1, height: 30).padding(.top, 14) }
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
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                Text(value).font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(.white)
                Text(note?.isEmpty == false ? note! : " ").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}
