import SystemServicesAPI
import ThermoUI
import AppKit
import CleanKit
import SwiftUI
import ThermoKit
import ThermoL10n

struct PerformanceCompactView: View {
    @ObservedObject var monitor: PerformanceModel
    @EnvironmentObject private var panel: PanelModel
    @EnvironmentObject private var pulse: SystemPulse
    @Environment(\.performanceNavigation) private var navigation
    @AppStorage(Settings.fahrenheit) private var fahrenheit = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                cpuCard; gpuCard; memoryCard; diskCard; networkCard; fanCard
            }
            if let battery = monitor.snapshot?.battery { batteryCard(battery) }
            programs
            if let error = monitor.lastError {
                Text(FanControlPresentation.errorText(error)).help(error).font(Theme.caption).foregroundStyle(Theme.danger).lineLimit(3)
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
            Text([m.map { PanelFormat.gb($0.usedBytes) + " / " + PanelFormat.gb($0.totalBytes) + " GiB" },
                  pulse.current.flatMap { $0.swapUsedMB > 0 ? tr("swap %1$@", MemoryFormat.string(mebibytes: $0.swapUsedMB)) : nil }]
                .compactMap { $0 }.joined(separator: " · "))
                .font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
        }
    }

    var diskCard: some View {
        let d = panel.diskStats
        let used = d.map { 1 - Double($0.freeBytes) / Double(max(1, $0.totalBytes)) } ?? 0
        return PanelCard(title: tr("Free space"), symbol: "internaldrive",
                         badge: d.map { tr("%1$@ total", ByteFormat.string($0.totalBytes)) }) {
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
        let stopped = monitor.stoppedFans
        let top = fans.filter { $0.reportedRPM(stopped: stopped) != nil }.max { $0.reportedRPM(stopped: stopped)! < $1.reportedRPM(stopped: stopped)! }
        return PanelCard(title: tr("Fans"), symbol: "fan",
                         badge: top?.load.map { String(format: "%.0f%%", $0 * 100) }) {
            BigValue(value: top.map { (fans.contains { $0.reportedRPM(stopped: stopped) == nil } ? "≥ " : "") + FanControlPresentation.rpm($0.reportedRPM(stopped: stopped)) } ?? "—", unit: top == nil ? nil : tr("RPM"))
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
                PanelButton(title: tr("Fan settings…")) { navigation.open(.fans) }
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
                Button { navigation.open(.compute(false)) } label: {
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
        // Only a project in the home folder names something; a daemon's "/System/Volumes/Data" does not.
        let home = NSHomeDirectory()
        let folder = h.project.flatMap { p -> String? in
            let full = p.hasPrefix("~") ? home + p.dropFirst() : p
            guard full.hasPrefix(home + "/") else { return nil }
            let name = (full as NSString).lastPathComponent
            return name.isEmpty || name == "null" ? nil : name
        }
        let owner = h.owner.flatMap { $0.isEmpty || $0 == "null" ? nil : $0 }
        let parts = [folder, owner].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

}
