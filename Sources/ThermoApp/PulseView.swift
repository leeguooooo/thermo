import CleanKit
import AppKit
import SwiftUI
import ThermoL10n

/// Samples `MachinePulse` every 3 s while the panel is open on the Overview tab; nothing runs otherwise.
final class SystemPulse: ObservableObject {
    typealias Hog = MachinePulse.Hog
    /// One sampler for the app; the card starts and stops it as it appears and disappears.
    static let shared = SystemPulse()

    @Published private(set) var current: MachinePulse?
    private let queue = DispatchQueue(label: "dev.thermo.app.pulse", qos: .utility)
    private var timer: DispatchSourceTimer?
    /// Confined to `queue`. Kept across start/stop so reopening shows fresh numbers in one cheap pass.
    private let sampler = PulseSampler()

    var sampled: Bool { current != nil }
    var hogs: [Hog] { current?.hogs ?? [] }
    var verdict: String { current?.verdictText ?? "" }
    var culprit: String? { current?.culpritText }
    var thermal: MachinePulse.Thermal { current?.thermal ?? .nominal }
    var memory: MachinePulse.Memory { current?.memory ?? .normal }

    var severity: Color {
        guard let p = current else { return .secondary }
        if p.thermal == .critical || p.busy >= 2 || p.memory == .critical { return .red }
        if p.thermal == .serious || p.busy >= 1 || p.memory == .warning { return .orange }
        return .green
    }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 3, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }

    deinit { timer?.cancel() }

    private func sample() {
        let p = sampler.sample()
        DispatchQueue.main.async { self.current = p }
    }

    /// Apps are asked to quit (they may save or refuse); other processes get SIGTERM.
    func quit(_ hog: Hog) {
        if let path = hog.app,
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.standardizedFileURL.path == path }) {
            app.terminate()
        } else {
            for pid in hog.pids where pid != getpid() { kill(pid, SIGTERM) }
        }
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.sample() }
    }

    /// The app being restarted, while it quits and comes back.
    @Published private(set) var restarting: String?

    /// Quit like ⌘Q, wait until every process of it has gone, then open it again; it restores its
    /// own windows and tabs. Gives up (and says so) if it is still running after a minute.
    func restart(_ hog: Hog) {
        guard let path = hog.app,
              let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.standardizedFileURL.path == path })
        else { return }
        restarting = hog.name
        app.terminate()
        let pids = hog.pids
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline, pids.contains(where: { kill($0, 0) == 0 }) { usleep(250_000) }
            let gone = !pids.contains(where: { kill($0, 0) == 0 })
            DispatchQueue.main.async {
                if gone {
                    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init()) { _, _ in }
                }
                self?.restarting = nil
            }
            self?.queue.asyncAfter(deadline: .now() + 3) { self?.sample() }
        }
    }
}

struct PulseCard: View {
    /// The panel is open. The popover's views outlive it being closed, so this, not onDisappear, stops sampling.
    let active: Bool
    @ObservedObject private var pulse = SystemPulse.shared
    @State private var confirming: SystemPulse.Hog?
    @State private var restartTarget: SystemPulse.Hog?
    @ObservedObject private var recorder = PulseRecorder.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: !pulse.sampled ? "hourglass" : pulse.severity == .green ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(pulse.sampled ? pulse.severity : .secondary).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pulse.sampled ? pulse.verdict : tr("Checking what your Mac is busy with…")).font(.callout.weight(.semibold))
                    if let c = pulse.culprit { Text(c).font(.caption).foregroundStyle(.secondary) }
                }
            }
            ForEach(pulse.hogs) { h in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(h.name).font(.callout).lineLimit(1)
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
                            Button(h.app != nil ? tr("Quit") : tr("End")) { confirming = h }
                                .controlSize(.small).modifier(ActionButtonStyle(prominent: false))
                        } else {
                            Color.clear.frame(height: 1)
                        }
                    }
                    .frame(width: 52, alignment: .trailing)
                }
                .padding(.leading, 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(recorder.highlighted == h.name ? Color.orange.opacity(0.18) : .clear))
                // A big app, split: its GPU process and heaviest pages.
                if let parts = h.parts, !parts.isEmpty {
                    Text(parts.map { "\(roleText($0.role)) \(memoryText($0.memoryKB))" }.joined(separator: " · "))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                        .padding(.leading, 28)
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
                    .padding(.leading, 28)
                }
            }
            if let note = pulse.current?.swapDiskText {
                Text(note).font(.caption2).foregroundStyle(.secondary).padding(.leading, 28)
            }
            PulseHistoryChart()
            HStack(spacing: 10) {
                label(tr("Temperature"), thermalText, thermalColor)
                label(tr("Memory"), memoryText, pulse.memory == .normal ? .secondary : pulse.memory == .warning ? .orange : .red)
            }
            .padding(.leading, 28)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill((pulse.sampled ? pulse.severity : .secondary).opacity(0.08)))
        .onAppear { if active { pulse.start() } }
        .onDisappear { pulse.stop() }  // switching tabs
        .onChange(of: active) { open in if open { pulse.start() } else { pulse.stop() } }
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
                         summary: tr("It is asked to quit, the same as ⌘Q (it can save first), then opened again; it reopens its windows and tabs. Whatever it piled up in memory is freed."),
                         destructive: false, heading: tr("What will run"),
                         lines: [tr("quit %1$@", h.app ?? h.name), tr("open %1$@", h.app ?? h.name)],
                         footnote: tr("If it is still running after a minute (for example asking to save), Thermo stops and does not reopen it."),
                         confirmTitle: tr("Restart"),
                         confirm: { restartTarget = nil; pulse.restart(h) }, cancel: { restartTarget = nil })
        }
    }

    /// "shop · started by Claude Code": the folder a command-line program runs in and who started it.
    func origin(_ h: SystemPulse.Hog) -> String? {
        let folder = h.project.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty || $0 == "~" ? nil : $0 }
        let parts = [folder, h.owner.map { tr("started by %1$@", $0) }].compactMap { $0 }
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
        case .normal: return tr("normal")
        case .warning: return tr("tight")
        case .critical: return tr("running out")
        }
    }

    func memoryText(_ kb: Int) -> String {
        kb >= 1_000_000 ? String(format: "%.1f GB", Double(kb) / 1_048_576) : "\(kb / 1024) MB"
    }
}
