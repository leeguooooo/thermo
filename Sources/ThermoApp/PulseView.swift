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
}

struct PulseCard: View {
    /// The panel is open. The popover's views outlive it being closed, so this, not onDisappear, stops sampling.
    let active: Bool
    @ObservedObject private var pulse = SystemPulse.shared
    @State private var confirming: SystemPulse.Hog?

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
                            Text(where_).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
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
            }
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
    }

    /// "~/tk.com/shop · Claude Code": the folder a command-line program runs in and who started it.
    func origin(_ h: SystemPulse.Hog) -> String? {
        let parts = [h.project, h.owner.map { tr("started by %1$@", $0) }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

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
