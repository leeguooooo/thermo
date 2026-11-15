import ThermoUI
import CleanKit
import AppKit
import SwiftUI
import ThermoL10n

struct PulseCard: View {
    /// The panel is open. The popover's views outlive it being closed, so this, not onDisappear, stops sampling.
    let active: Bool
    /// On a glass panel (main window): no tinted background of its own.
    var plain = false
    /// False on the main window's overview, which says the verdict, thermal pressure and history itself.
    var headline = true
    private var indent: CGFloat { headline ? 28 : 0 }
    @EnvironmentObject private var pulse: SystemPulse
    @Environment(\.performanceNavigation) private var navigation
    @Environment(\.performanceInspections) private var inspections
    @State private var confirming: SystemPulse.Hog?
    @State private var restartTarget: SystemPulse.Hog?
    @State private var explaining: ProcessInspectionTarget?
    @State private var holds = false
    @EnvironmentObject private var recorder: PulseRecorder

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if headline {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: !pulse.sampled ? "hourglass" : pulse.severity == .green ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(pulse.sampled ? pulse.severity : .secondary).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pulse.sampled ? pulse.verdict : tr("Checking what your Mac is busy with…")).font(.callout.weight(.semibold))
                    if let c = pulse.culprit { Text(c).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if let next = pulse.current?.nextStep {
                Text(next.text).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, indent)
            }
            }
            // The main window shows it on the Overview itself, above the vitals.
            if !plain { SlowdownCulpritsCard().padding(.leading, indent) }
            if plain { table } else {
            ForEach(pulse.hogs) { h in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(h.name).font(.callout).lineLimit(1)
                            if !renderingPreview, let identity = h.applicationIdentity ?? h.processIdentities?.first {
                                Button { explaining = .init(identity: identity, candidates: h.processIdentities ?? []) } label: { Image(systemName: "info.circle") }
                                    .buttonStyle(.plain).help(tr("Why is this running?"))
                                    .accessibilityLabel(tr("Why is %1$@ running?", h.name))
                            }
                            if h.pids.count > 1 && h.app == nil {
                                Text("×\(h.pids.count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        if let where_ = origin(h) {
                            // The project's own folder name, never cut mid-word; the full path on hover.
                            Text(where_).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                                .help(h.project ?? "")
                        }
                    }
                    Spacer(minLength: 4)
                    Text(String(format: "%.0f%%", h.cpu)).font(.callout.monospacedDigit())
                        .foregroundStyle(h.cpu >= 100 ? .red : h.cpu >= 50 ? .orange : .primary)
                        .frame(width: 44, alignment: .trailing)
                    Text(memoryText(h.memoryKB)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .trailing)
                    // Fixed width whether or not there is a button, so the columns line up.
                    Group {
                        if h.quittable && !renderingPreview {
                            Button(pulse.quitting.contains(h.id) ? tr("Stopping…") : h.app != nil ? tr("Quit") : tr("End")) { confirming = h }
                                .controlSize(.small).modifier(ActionButtonStyle(prominent: false))
                                .disabled(pulse.quitting.contains(h.id) || pulse.restarting == h.name)
                        } else {
                            Color.clear.frame(height: 1)
                        }
                    }
                    .frame(width: 52, alignment: .trailing)
                }
                .padding(.leading, indent)
                .background(RoundedRectangle(cornerRadius: 6).fill(recorder.highlighted == h.name ? Color.orange.opacity(0.18) : .clear))
                // A big app, split: its GPU process and heaviest pages.
                if let parts = h.parts, !parts.isEmpty {
                    Text(parts.map { "\(roleText($0.role)) \(memoryText($0.memoryKB))" }.joined(separator: " · "))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                        .padding(.leading, indent)
                }
                // A browser: which of its pages is the problem (measured only when asked).
                if ChromeInspector.isBrowser(h.name) && !renderingPreview {
                    Button(tr("View pages")) {
                        navigation.showBrowser(h)
                    }
                    .controlSize(.small).buttonStyle(.link).font(.caption)
                    .padding(.leading, indent)
                }
                if let a = h.advice {
                    HStack(alignment: .top, spacing: 6) {
                        Text(a.text).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        if !renderingPreview {
                            Button(pulse.restarting == h.name ? tr("Restarting…") : tr("Restart")) { restartTarget = h }
                                .controlSize(.small).modifier(ActionButtonStyle(prominent: true))
                                .disabled(pulse.restarting != nil)
                        }
                    }
                    .padding(.leading, indent)
                }
            }
            }
            if let problem = pulse.quitProblem {
                Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).padding(.leading, indent)
            }
            if let problem = pulse.restartProblem {
                Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).padding(.leading, indent)
            }
            if let feedback = pulse.actionFeedback {
                Text(feedback).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, indent)
            }
            if let note = pulse.current?.diskText {
                Text(note).font(.caption).foregroundStyle(.orange).padding(.leading, indent)
            }
            if let note = pulse.current?.swapDiskText {
                Text(note).font(.caption2).foregroundStyle(.secondary).padding(.leading, indent)
            }
            if headline {
                PulseHistoryChart(recorder: recorder)
                HStack(spacing: 10) {
                    label(tr("Thermal pressure"), thermalText, thermalColor)
                    label(tr("Memory"), memoryText, pulse.memory == .normal ? .secondary : pulse.memory == .warning ? .orange : .red)
                }
                .padding(.leading, indent)
            }
        }
        .padding(plain ? 0 : 10)
        .background(RoundedRectangle(cornerRadius: 8).fill((pulse.sampled ? pulse.severity : .secondary).opacity(plain ? 0 : 0.08)))
        .onAppear { holding(active) }
        .onDisappear { holding(false) }  // switching pages
        .onChange(of: active) { holding($0) }
        .sheet(item: $confirming) { h in
            ConfirmSheet(title: h.app != nil ? tr("Quit %1$@?", h.name) : tr("End %1$@?", h.name),
                         summary: h.app != nil ? tr("The app is asked to quit, the same as ⌘Q; it can save your work first.")
                                                     : tr("The process is asked to stop (SIGTERM). Unsaved work in it may be lost."),
                         destructive: h.app == nil, heading: tr("What will run"),
                         lines: h.app != nil ? [tr("quit %1$@", h.app!)] : h.pids.map { "kill -TERM \($0)" },
                         footnote: tr("Thermo never stops system processes, AI agent sessions or itself."),
                         confirmTitle: h.app != nil ? tr("Quit") : tr("End"),
                         confirm: { confirming = nil; pulse.quit(h) }, cancel: { confirming = nil })
        }
        .sheet(item: $restartTarget) { h in
            ConfirmSheet(title: tr("Restart %1$@?", h.name),
                         summary: MachinePulse.sentences(tr("It is asked to quit, the same as ⌘Q (it can save first), then opened again. Thermo then checks whether its memory use decreased."),
                                                         MachinePulse.restartNote(BrowserSession.windows(for: h.name))),
                         destructive: BrowserSession.windows(for: h.name) == .unknown, heading: tr("What will run"),
                         lines: [tr("quit %1$@", h.app ?? h.name), tr("open %1$@", h.app ?? h.name)]
                            + (BrowserSession.windows(for: h.name) == .thermoReopensTabs ? [tr("save its tabs, then open them again")] : []),
                         footnote: tr("If it is still running after a minute (for example asking to save), Thermo stops and does not reopen it."),
                         confirmTitle: tr("Restart"),
                         confirm: { restartTarget = nil; pulse.restart(h) }, cancel: { restartTarget = nil })
        }
        .sheet(item: $explaining) { ProcessExplanationView(target: $0, makeModel: inspections.make) }
    }

    // MARK: Table (main window)

    /// The busiest programs as a table: name and where it runs, CPU with a bar, memory, action.
    @ViewBuilder var table: some View {
        if !pulse.sampled && pulse.hogs.isEmpty {
            SkeletonList(rows: 4)
        } else if pulse.hogs.isEmpty {
            InspectorPanel { EmptyState(symbol: "leaf", title: tr("Nothing is keeping your Mac busy")) }
        } else {
            InspectorPanel {
                HStack(spacing: Theme.Space.m) {
                    Text(tr("Program")).frame(maxWidth: .infinity, alignment: .leading)
                    Text("CPU").frame(width: 96, alignment: .trailing)
                    Text(tr("Memory")).frame(width: 70, alignment: .trailing)
                    Color.clear.frame(width: 120, height: 1)
                }
                .font(Theme.label).foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s)
                ForEach(pulse.hogs) { h in
                    InspectorDivider(inset: Theme.Space.l)
                    tableRow(h)
                }
            }
        }
    }

    func tableRow(_ h: SystemPulse.Hog) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.m) {
                Group {
                    if let app = h.app {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app)).resizable()
                    } else {
                        Image(systemName: "terminal").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textSecondary)
                            .frame(width: 24, height: 24)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.07)))
                    }
                }
                .frame(width: 24, height: 24).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(h.name).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        if h.pids.count > 1 && h.app == nil {
                            Text("×\(h.pids.count)").font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                        }
                        if !renderingPreview, let identity = h.applicationIdentity ?? h.processIdentities?.first {
                            Button { explaining = .init(identity: identity, candidates: h.processIdentities ?? []) } label: {
                                Image(systemName: "questionmark.circle").font(.system(size: 11))
                            }
                            .buttonStyle(.plain).foregroundStyle(Theme.textTertiary).help(tr("Why is this running?"))
                            .accessibilityLabel(tr("Why is %1$@ running?", h.name))
                        }
                    }
                    if let line = subtitle(h) {
                        Text(line).font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                            .lineLimit(1).truncationMode(.tail).help(h.project ?? line)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.07))
                            Capsule().fill(cpuColor(h.cpu)).frame(width: g.size.width * CGFloat(min(1, max(0, h.cpu / max(100, pulse.hogs.map(\.cpu).max() ?? 100)))))
                        }
                    }
                    .frame(width: 44, height: 4).accessibilityHidden(true)
                    Text(String(format: "%.0f%%", h.cpu)).font(Theme.figure(.row, weight: .medium))
                        .foregroundStyle(h.cpu >= 50 ? cpuColor(h.cpu) : Theme.textPrimary)
                        .contentTransition(.numericText())
                        .frame(width: 44, alignment: .trailing)
                }
                .frame(width: 96, alignment: .trailing)
                Text(memoryText(h.memoryKB)).font(Theme.figure(.row, weight: .medium)).foregroundStyle(Theme.textSecondary)
                    .contentTransition(.numericText())
                    .frame(width: 70, alignment: .trailing)
                HStack(spacing: 6) {
                    if ChromeInspector.isBrowser(h.name) && !renderingPreview {
                        Button(tr("Pages")) {
                            navigation.showBrowser(h)
                        }
                        .buttonStyle(PillButtonStyle()).controlSize(.small).help(tr("View pages"))
                    }
                    if h.quittable && !renderingPreview {
                        Button(pulse.quitting.contains(h.id) ? tr("Stopping…") : h.app != nil ? tr("Quit") : tr("End")) { confirming = h }
                            .buttonStyle(PillButtonStyle()).controlSize(.small)
                            .disabled(pulse.quitting.contains(h.id) || pulse.restarting == h.name)
                    }
                }
                .frame(width: 120, alignment: .trailing)
            }
            if let a = h.advice {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "lightbulb").font(.system(size: 11)).foregroundStyle(Theme.caution)
                    Text(a.text).font(Theme.caption).foregroundStyle(Theme.caution).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if !renderingPreview {
                        Button(pulse.restarting == h.name ? tr("Restarting…") : tr("Restart")) { restartTarget = h }
                            .buttonStyle(PillButtonStyle(prominent: true, color: Theme.caution)).controlSize(.small)
                            .disabled(pulse.restarting != nil)
                    }
                }
                .padding(.leading, 36)
            }
        }
        .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s)
        .background(recorder.highlighted == h.name ? Theme.caution.opacity(0.10) : .clear)
        .hoverHighlight()
    }

    /// Where it runs, or what it is made of: its processes summed by kind ("Pages ×12 4.1 GiB"),
    /// never one entry per process.
    func subtitle(_ h: SystemPulse.Hog) -> String? {
        var items: [String] = []
        if let o = origin(h) { items.append(o) }
        if let parts = h.parts, parts.count > 1 {
            let roles = Dictionary(grouping: parts, by: \.role)
                .map { (role: $0.key, count: $0.value.count, kb: $0.value.reduce(0) { $0 + $1.memoryKB }) }
                .sorted { $0.kb > $1.kb }
            items += roles.prefix(3).map { r in
                roleText(r.role) + (r.count > 1 ? " ×\(r.count)" : "") + " " + memoryText(r.kb)
            }
        }
        return items.isEmpty ? nil : items.joined(separator: "  ·  ")
    }

    func cpuColor(_ cpu: Double) -> Color { cpu >= 100 ? Theme.danger : cpu >= 50 ? Theme.caution : Theme.accent }

    /// This card's share in keeping the sampler running (the panel and the main window each have one).
    func holding(_ on: Bool) {
        guard on != holds else { return }
        holds = on
        if on { pulse.hold() } else { pulse.release() }
    }

    /// Working folder plus current ancestor evidence; not an original-launcher claim.
    func origin(_ h: SystemPulse.Hog) -> String? {
        let folder = h.project.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty || $0 == "~" ? nil : $0 }
        let parts = [folder, h.owner.map { tr("observed ancestor: %1$@", $0) }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func roleText(_ role: String) -> String { MachinePulse.roleName(role) }

    func label(_ title: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Text(title).foregroundStyle(.secondary)
            Text(value).foregroundStyle(color)
        }
        .font(.caption)
    }

    var thermalText: String {
        switch pulse.thermal {
        case .nominal: return tr("normal")
        case .fair: return tr("warm")
        case .serious: return tr("hot, slowing down")
        case .critical: return tr("critical, slowing down")
        }
    }

    var thermalColor: Color {
        switch pulse.thermal {
        case .nominal: return .secondary
        case .fair: return .yellow
        case .serious: return .orange
        default: return .red
        }
    }

    var memoryText: String {
        switch pulse.memory {
        case .unknown: return tr("unavailable")
        case .normal: return tr("normal")
        case .warning: return tr("tight")
        case .critical: return tr("running out")
        }
    }

    func memoryText(_ kb: Int) -> String {
        MemoryFormat.string(kibibytes: kb)
    }
}
