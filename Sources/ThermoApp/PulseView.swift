import AgentCore
import AppKit
import SwiftUI
import ThermoL10n

/// "Why is my Mac slow?": load against cores, thermal throttling, memory pressure and the processes
/// using the most CPU. Samples only while the card is on screen.
final class SystemPulse: ObservableObject {
    /// One sampler for the app; the card starts and stops it as it appears and disappears.
    static let shared = SystemPulse()

    /// One program: an app with all its helper processes, or a single command-line process.
    struct Hog: Identifiable, Equatable {
        var id: String
        var name: String
        var cpu: Double
        var rssKB: Int
        var pids: [pid_t]
        /// Set for GUI apps; quitting goes through the app so it can save its work.
        var bundleURL: URL?
        /// Nil when Thermo offers no quit button (not ours, an agent session, Thermo itself).
        var quittable: Bool
    }

    enum Memory: Equatable { case normal, warning, critical }

    @Published private(set) var load: Double = 0
    @Published private(set) var cores = ProcessInfo.processInfo.activeProcessorCount
    @Published private(set) var thermal: ProcessInfo.ThermalState = .nominal
    @Published private(set) var memory: Memory = .normal
    @Published private(set) var hogs: [Hog] = []
    @Published private(set) var sampled = false

    private let queue = DispatchQueue(label: "dev.thermo.app.pulse", qos: .utility)
    private var timer: DispatchSourceTimer?

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
        var avg = [Double](repeating: 0, count: 3)
        getloadavg(&avg, 3)
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        let mem: Memory = level >= 4 ? .critical : level >= 2 ? .warning : .normal
        let hogs = Self.group(ProcessTable.current(.init(cpu: true)).entries, byMemory: mem != .normal)
        let thermal = ProcessInfo.processInfo.thermalState
        DispatchQueue.main.async {
            self.load = avg[0]; self.memory = mem; self.thermal = thermal; self.hogs = hogs; self.sampled = true
        }
    }

    /// Folds helper processes into their app and returns the busiest programs.
    static func group(_ procs: [AgentProcess], byMemory: Bool = false) -> [Hog] {
        let me = getpid()
        var byKey: [String: Hog] = [:]
        for p in procs where p.cpu > 0.5 || p.rssKB > 200_000 {
            let exe = p.executable ?? ""
            var key = "pid:\(p.pid)"
            var name = (p.argv.first.map { ($0 as NSString).lastPathComponent } ?? p.name)
            var bundle: URL?
            if let r = exe.range(of: ".app/") {
                let appPath = String(exe[..<r.lowerBound]) + ".app"
                key = appPath
                bundle = URL(fileURLWithPath: appPath)
                name = FileManager.default.displayName(atPath: appPath).replacingOccurrences(of: ".app", with: "")
            }
            let lower = name.lowercased()
            let agent = ProcessTable.agentNames.contains(lower) || exe.contains("/claude/versions/")
            let quittable = p.pid != me && p.uid == getuid() && !agent && !exe.hasPrefix("/System/") && !exe.hasPrefix("/usr/")
            var h = byKey[key] ?? Hog(id: key, name: name, cpu: 0, rssKB: 0, pids: [], bundleURL: bundle, quittable: quittable)
            h.cpu += p.cpu
            h.rssKB += p.rssKB
            h.pids.append(p.pid)
            h.quittable = h.quittable && quittable
            byKey[key] = h
        }
        var top = Array(byKey.values.sorted { $0.cpu > $1.cpu }.prefix(4).filter { $0.cpu >= 5 })
        // Under memory pressure the biggest programs matter as much as the busiest ones.
        if byMemory {
            for h in byKey.values.sorted(by: { $0.rssKB > $1.rssKB }).prefix(2) where !top.contains(where: { $0.id == h.id }) {
                top.append(h)
            }
        }
        return top
    }

    var busy: Double { load / Double(max(1, cores)) }

    /// One sentence a person can act on.
    var verdict: String {
        if thermal == .critical || thermal == .serious { return tr("Your Mac is too hot and is slowing itself down") }
        if busy >= 2 { return tr("Your Mac is overloaded: load %1$@ on %2$@ cores", String(Int(load.rounded())), String(cores)) }
        if memory != .normal { return tr("Memory is running out") }
        if busy >= 1 { return tr("Your Mac is busy: load %1$@ on %2$@ cores", String(Int(load.rounded())), String(cores)) }
        return tr("Nothing is slowing your Mac down right now")
    }

    var culprit: String? {
        if let top = hogs.first, top.cpu >= 50 {
            return tr("Mostly %1$@, using %2$@ cores", top.name, String(format: "%.1f", top.cpu / 100))
        }
        // High load without a busy program: processes are waiting, usually on memory or the disk.
        if memory != .normal, let big = hogs.max(by: { $0.rssKB < $1.rssKB }) {
            return tr("Memory is tight, so macOS keeps swapping to disk; %1$@ uses the most (%2$@)",
                      big.name, String(format: "%.1f GB", Double(big.rssKB) / 1_048_576))
        }
        if busy >= 1 { return tr("No single program stands out; many are waiting on the disk") }
        return nil
    }

    var severity: Color {
        if thermal == .critical || busy >= 2 || memory == .critical { return .red }
        if thermal == .serious || busy >= 1 || memory == .warning { return .orange }
        return .green
    }

    /// Apps are asked to quit (they may save or refuse); other processes get SIGTERM.
    func quit(_ hog: Hog) {
        if let url = hog.bundleURL,
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }) {
            app.terminate()
        } else {
            for pid in hog.pids where pid != getpid() { kill(pid, SIGTERM) }
        }
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.sample() }
    }
}

struct PulseCard: View {
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
                HStack(spacing: 6) {
                    Text(h.name).font(.callout).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.0f%%", h.cpu)).font(.callout.monospacedDigit())
                        .foregroundStyle(h.cpu >= 100 ? .red : h.cpu >= 50 ? .orange : .primary)
                        .frame(width: 52, alignment: .trailing)
                    Text(memoryText(h.rssKB)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .trailing)
                    if h.quittable && !renderingPreview {
                        Button(h.bundleURL != nil ? tr("Quit") : tr("End")) { confirming = h }
                            .controlSize(.small).modifier(ActionButtonStyle(prominent: false))
                    } else {
                        Color.clear.frame(width: 44, height: 1)
                    }
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
        .onAppear { pulse.start() }
        .onDisappear { pulse.stop() }
        .sheet(item: $confirming) { h in
            ConfirmSheet(title: h.bundleURL != nil ? tr("Quit %1$@?", h.name) : tr("End %1$@?", h.name),
                         summary: h.bundleURL != nil ? tr("The app is asked to quit, the same as ⌘Q; it can save your work first.")
                                                     : tr("The process is asked to stop (SIGTERM). Unsaved work in it may be lost."),
                         destructive: h.bundleURL == nil, heading: tr("What will run"),
                         lines: h.bundleURL != nil ? [tr("quit %1$@", h.bundleURL!.path)] : h.pids.map { "kill -TERM \($0)" },
                         footnote: tr("Thermo never stops system processes, AI agent sessions or itself."),
                         confirmTitle: h.bundleURL != nil ? tr("Quit") : tr("End"),
                         confirm: { confirming = nil; pulse.quit(h) }, cancel: { confirming = nil })
        }
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
        @unknown default: return "—"
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
