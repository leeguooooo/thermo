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
    @Published private(set) var quitProblem: String?
    @Published private(set) var quitting: Set<String> = []
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

    /// Cards showing the pulse (panel and main window): sampling runs while at least one is visible.
    private var holders = 0
    func hold() { holders += 1; if holders == 1 { start() } }
    func release() { holders = max(0, holders - 1); if holders == 0 { stop() } }

    deinit { timer?.cancel() }

    private func sample() {
        let p = sampler.sample()
        DispatchQueue.main.async {
            var pulse = p
            for index in pulse.hogs.indices {
                if let path = pulse.hogs[index].app,
                   let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.standardizedFileURL.path == path }) {
                    pulse.hogs[index].applicationIdentity = ProcessTable.identity(app.processIdentifier)
                }
            }
            self.current = pulse
        }
    }

    /// Apps are asked to quit (they may save or refuse); other processes get SIGTERM.
    func quit(_ hog: Hog) {
        quitProblem = nil
        guard hog.quittable, !quitting.contains(hog.id) else { return }
        if let path = hog.app {
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.standardizedFileURL.path == path }),
                  let expected = hog.applicationIdentity,
                  Self.canSignal(expected, current: ProcessTable.identity(app.processIdentifier)) else {
                quitProblem = tr("%1$@ changed or exited since the reading. Check again before stopping it.", hog.name)
                return
            }
            if !app.terminate() { quitProblem = tr("%1$@ did not accept the quit request. Check its dialogs.", hog.name) }
        } else {
            let identities = hog.processIdentities ?? []
            var skipped = identities.count != hog.pids.count
            for expected in identities {
                guard hog.pids.contains(expected.pid), Self.canSignal(expected, current: ProcessTable.identity(expected.pid)) else {
                    skipped = true
                    continue
                }
                if kill(expected.pid, SIGTERM) != 0 { skipped = true }
            }
            if skipped { quitProblem = tr("%1$@ changed or exited since the reading. Check again before stopping it.", hog.name) }
        }
        quitting.insert(hog.id)
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.sample() }
        let identities = hog.app == nil ? hog.processIdentities ?? [] : hog.applicationIdentity.map { [$0] } ?? []
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            let stillRunning = identities.contains { Self.canSignal($0, current: ProcessTable.identity($0.pid)) }
            DispatchQueue.main.async {
                self?.quitting.remove(hog.id)
                if stillRunning {
                    self?.quitProblem = tr("%1$@ is still running. Check any save dialogs before trying again.", hog.name)
                }
            }
            self?.sample()
        }
    }

    static func canSignal(_ expected: ProcessIdentity, current: ProcessIdentity?, uid: UInt32 = getuid(), me: Int32 = getpid()) -> Bool {
        expected.pid > 1 && expected.pid != me && expected.uid == uid && expected == current
    }

    /// The app being restarted, while it quits and comes back.
    @Published private(set) var restarting: String?
    /// Why the last restart did not go as planned.
    @Published var restartProblem: String?

    /// Quit like ⌘Q, wait until every process of it has gone, then open it again; it restores its
    /// own windows and tabs. Gives up (and says so) if it is still running after a minute.
    func restart(_ hog: Hog) {
        guard hog.quittable, restarting == nil, !quitting.contains(hog.id) else { return }
        guard let path = hog.app,
              let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.standardizedFileURL.path == path })
        else { return }
        guard let expected = hog.applicationIdentity,
              Self.canSignal(expected, current: ProcessTable.identity(app.processIdentifier)) else {
            restartProblem = tr("%1$@ changed or exited since the reading. Check again before stopping it.", hog.name)
            return
        }
        restarting = hog.name
        restartProblem = nil
        let pids = hog.pids, name = hog.name
        let windows = BrowserSession.windows(for: name)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // A browser that would lose its tabs: save them first, or don't restart at all.
            var saved: BrowserSession.Saved?
            if windows == .thermoReopensTabs {
                saved = BrowserSession.save(app: name)
                if saved == nil {
                    DispatchQueue.main.async {
                        self?.restarting = nil
                        self?.restartProblem = tr("Thermo could not list %1$@'s tabs, so it did not restart it (they would be lost). Allow Thermo in System Settings → Privacy & Security → Automation.", name)
                    }
                    return
                }
            }
            DispatchQueue.main.sync { _ = app.terminate() }
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline, pids.contains(where: { kill($0, 0) == 0 }) { usleep(250_000) }
            let gone = !pids.contains(where: { kill($0, 0) == 0 })
            if gone {
                let opened = DispatchSemaphore(value: 0)
                let outcome = LaunchOutcome()
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init()) { app, error in
                    outcome.record(app != nil && error == nil)
                    opened.signal()
                }
                let completed = opened.wait(timeout: .now() + 30) == .success
                if !completed || !outcome.succeeded {
                    DispatchQueue.main.async {
                        self?.restartProblem = tr("Could not reopen %1$@. Open it manually.", name)
                            + (saved == nil ? "" : " " + tr("Saved tabs are in %1$@.", BrowserSession.backupURL().path))
                    }
                } else if let saved, !BrowserSession.reopen(saved) {
                    DispatchQueue.main.async {
                        self?.restartProblem = tr("%1$@ restarted, but its tabs could not be reopened. They are listed in %2$@.", name, BrowserSession.backupURL().path)
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self?.restartProblem = tr("%1$@ is still running. Finish any save dialogs, then try again.", name)
                }
            }
            DispatchQueue.main.async { self?.restarting = nil }
            self?.queue.asyncAfter(deadline: .now() + 3) { self?.sample() }
        }
    }
}

/// The workspace completion and the waiting background queue exchange one result.
private final class LaunchOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var success = false
    func record(_ success: Bool) { lock.lock(); self.success = success; lock.unlock() }
    var succeeded: Bool { lock.lock(); defer { lock.unlock() }; return success }
}

struct PulseCard: View {
    /// The panel is open. The popover's views outlive it being closed, so this, not onDisappear, stops sampling.
    let active: Bool
    /// On a glass panel (main window): no tinted background of its own.
    var plain = false
    @ObservedObject private var pulse = SystemPulse.shared
    @State private var confirming: SystemPulse.Hog?
    @State private var restartTarget: SystemPulse.Hog?
    @State private var holds = false
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
                            Button(pulse.quitting.contains(h.id) ? tr("Stopping…") : h.app != nil ? tr("Quit") : tr("End")) { confirming = h }
                                .controlSize(.small).modifier(ActionButtonStyle(prominent: false))
                                .disabled(pulse.quitting.contains(h.id) || pulse.restarting == h.name)
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
                // A browser: which of its pages is the problem (measured only when asked).
                if ChromeInspector.isBrowser(h.name) && !renderingPreview {
                    Button(tr("View pages")) {
                        _ = AppModels.shared.browser(h.name, memoryKB: h.memoryKB, gpuKB: h.parts?.first { $0.role == "GPU" }?.memoryKB)
                        MainWindow.show(.browser(h.name))
                    }
                    .controlSize(.small).buttonStyle(.link).font(.caption)
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
            if let problem = pulse.quitProblem {
                Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).padding(.leading, 28)
            }
            if let problem = pulse.restartProblem {
                Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).padding(.leading, 28)
            }
            if let note = pulse.current?.swapDiskText {
                Text(note).font(.caption2).foregroundStyle(.secondary).padding(.leading, 28)
            }
            PulseHistoryChart()
            HStack(spacing: 10) {
                label(tr("Thermal pressure"), thermalText, thermalColor)
                label(tr("Memory"), memoryText, pulse.memory == .normal ? .secondary : pulse.memory == .warning ? .orange : .red)
            }
            .padding(.leading, 28)
        }
        .padding(10)
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
                         summary: MachinePulse.sentences(tr("It is asked to quit, the same as ⌘Q (it can save first), then opened again. Whatever it piled up in memory is freed."),
                                                         MachinePulse.restartNote(BrowserSession.windows(for: h.name))),
                         destructive: BrowserSession.windows(for: h.name) == .unknown, heading: tr("What will run"),
                         lines: [tr("quit %1$@", h.app ?? h.name), tr("open %1$@", h.app ?? h.name)]
                            + (BrowserSession.windows(for: h.name) == .thermoReopensTabs ? [tr("save its tabs, then open them again")] : []),
                         footnote: tr("If it is still running after a minute (for example asking to save), Thermo stops and does not reopen it."),
                         confirmTitle: tr("Restart"),
                         confirm: { restartTarget = nil; pulse.restart(h) }, cancel: { restartTarget = nil })
        }
    }

    /// This card's share in keeping the sampler running (the panel and the main window each have one).
    func holding(_ on: Bool) {
        guard on != holds else { return }
        holds = on
        if on { pulse.hold() } else { pulse.release() }
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
