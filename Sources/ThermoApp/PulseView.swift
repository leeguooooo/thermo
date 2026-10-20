import CleanKit
import AppKit
import SwiftUI
import ThermoL10n

/// Timer callbacks run on a worker queue; lifetime changes and publication run
/// on the UI thread. A new visible session must reject an old session's result.
private final class PulseSamplingLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var token: UUID?
    func start() -> UUID {
        lock.lock(); defer { lock.unlock() }
        let value = UUID(); token = value; return value
    }
    func stop() { lock.lock(); token = nil; lock.unlock() }
    func current() -> UUID? { lock.lock(); defer { lock.unlock() }; return token }
    func accepts(_ value: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return token == value }
}

/// Samples `MachinePulse` every 3 s while the panel is open on the Overview tab; nothing runs otherwise.
final class SystemPulse: ObservableObject {
    typealias Hog = MachinePulse.Hog
    /// One sampler for the app; the card starts and stops it as it appears and disappears.
    static let shared = SystemPulse()

    @Published private(set) var current: MachinePulse?
    @Published private(set) var quitProblem: String?
    @Published private(set) var quitting: Set<String> = []
    @Published private(set) var actionFeedback: String?
    private var reviewID = UUID()
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    /// Confined to `queue`. Kept across start/stop so reopening shows fresh numbers in one cheap pass.
    private let sampler = PulseSampler()
    private let lifetime = PulseSamplingLifetime()
    private let readSample: (@Sendable () -> MachinePulse)?

    init(readSample: (@Sendable () -> MachinePulse)? = nil, samplingQueue: DispatchQueue? = nil) {
        self.readSample = readSample
        queue = samplingQueue ?? DispatchQueue(label: "dev.thermo.app.pulse", qos: .userInitiated)
    }

    #if DEBUG
    private static let tracing = ProcessInfo.processInfo.environment["THERMO_PULSE_TRACE"] == "1" &&
        CommandLine.arguments.contains("--verify-lifecycle")
    private static func trace(_ event: String, _ token: UUID? = nil) {
        guard tracing else { return }
        print("PULSE_TRACE \(DispatchTime.now().uptimeNanoseconds) \(event) \(token?.uuidString ?? "-")")
        fflush(stdout)
    }
    #endif

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
        let token = lifetime.start()
        #if DEBUG
        Self.trace("start", token)
        #endif
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 3, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.sample(token: token) }
        t.resume()
        timer = t
    }

    func stop() {
        #if DEBUG
        Self.trace("stop", lifetime.current())
        #endif
        lifetime.stop(); timer?.cancel(); timer = nil
    }

    /// Cards showing the pulse (panel and main window): sampling runs while at least one is visible.
    private var holders = 0
    var samplingActive: Bool { timer != nil }
    var holderCount: Int { holders }
    func hold() { holders += 1; if holders == 1 { start() } }
    func release() { holders = max(0, holders - 1); if holders == 0 { stop() } }

    deinit { timer?.cancel() }

    private func sample(token supplied: UUID? = nil) {
        guard let token = supplied ?? lifetime.current(), lifetime.accepts(token) else { return }
        #if DEBUG
        Self.trace("read-start", token)
        #endif
        let p = readSample?() ?? sampler.sample()
        #if DEBUG
        Self.trace("read-end", token)
        #endif
        DispatchQueue.main.async {
            guard self.lifetime.accepts(token) else {
                #if DEBUG
                Self.trace("discard", token)
                #endif
                return
            }
            #if DEBUG
            Self.trace("main-start", token)
            #endif
            var pulse = p
            for index in pulse.hogs.indices {
                if let path = pulse.hogs[index].app,
                   let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.standardizedFileURL.path == path }) {
                    pulse.hogs[index].applicationIdentity = ProcessTable.identity(app.processIdentifier)
                }
            }
            #if DEBUG
            Self.trace("publish", token)
            #endif
            self.current = pulse
            MainActor.assumeIsolated { TimelineEvents.shared.observe(pulse) }
        }
    }

    /// Recheck the entire process inventory; an idle reopened app can fall out of the busiest list.
    private func review(_ hog: Hog, before: MachinePulse, action: PulseActionReview.Action) {
        let id = UUID(); reviewID = id
        actionFeedback = tr("Checking the effect of the action…")
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            let after = self.sampler.sample()
            let all = MachinePulse.group(ProcessTable.current(.init(cpu: false)).entries, byMemory: true, limit: nil)
            let result = PulseActionReview(action: action, target: hog, before: before, after: after,
                                           afterTarget: PulseActionReview.findTarget(hog, in: all), inventoryAvailable: !all.isEmpty)
            result.record()
            DispatchQueue.main.async {
                guard self.reviewID == id else { return }
                self.actionFeedback = MachinePulse.sentences(result.summary, result.detail)
            }
            self.sample()
        }
    }

    /// Apps are asked to quit (they may save or refuse); other processes get SIGTERM.
    func quit(_ hog: Hog) {
        quitProblem = nil
        guard hog.quittable, !quitting.contains(hog.id) else { return }
        let before = current
        let baseline = current?.hogs.first { $0.id == hog.id }
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
        if let before, let baseline { review(baseline, before: before, action: .quit) }
        else { actionFeedback = tr("The follow-up readings cannot be compared. Check again.") }
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
        let before = current
        let baseline = current?.hogs.first { $0.id == hog.id }
        restarting = hog.name
        restartProblem = nil
        actionFeedback = nil
        reviewID = UUID()
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
                if completed && outcome.succeeded {
                    DispatchQueue.main.async {
                        if let before, let baseline { self?.review(baseline, before: before, action: .restart) }
                        else { self?.actionFeedback = tr("The follow-up readings cannot be compared. Check again.") }
                    }
                }
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
    /// False on the main window's overview, which says the verdict, thermal pressure and history itself.
    var headline = true
    private var indent: CGFloat { headline ? 28 : 0 }
    @ObservedObject private var pulse = SystemPulse.shared
    @State private var confirming: SystemPulse.Hog?
    @State private var restartTarget: SystemPulse.Hog?
    @State private var explaining: ProcessInspectionTarget?
    @State private var holds = false
    @ObservedObject private var recorder = PulseRecorder.shared

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
                        _ = AppModels.shared.browser(h.name, memoryKB: h.memoryKB, gpuKB: h.parts?.first { $0.role == "GPU" }?.memoryKB)
                        MainWindow.show(.browser(h.name))
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
                PulseHistoryChart()
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
        .sheet(item: $explaining) { ProcessExplanationView(target: $0) }
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
                    .animation(Theme.gentle, value: h.cpu)
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
                            _ = AppModels.shared.browser(h.name, memoryKB: h.memoryKB, gpuKB: h.parts?.first { $0.role == "GPU" }?.memoryKB)
                            MainWindow.show(.browser(h.name))
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
