import NativeFeatureAPI
import ThermoUI
import CleanKit
import AppKit
import SwiftUI
import ThermoL10n
import ModuleKit

/// Samples `MachinePulse` every 3 s while the panel is open on the Overview tab; nothing runs otherwise.
final class SystemPulse: ObservableObject {
    typealias Hog = MachinePulse.Hog
    /// The owning performance session shares it between its visible cards.

    @Published private(set) var current: MachinePulse?
    @Published private(set) var quitProblem: String?
    @Published private(set) var quitting: Set<String> = []
    @Published private(set) var actionFeedback: String?
    private var reviewID = UUID()
    // Main-thread ownership lasts from scheduling through the real read, journal write and UI receipt.
    private var pendingActionReviews = Set<UUID>()
    private var actionReviewWaiters: [CheckedContinuation<Void, Never>] = []
    var actionReviewInFlight: Bool { !pendingActionReviews.isEmpty }
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    /// Confined to `queue`. Kept across start/stop so reopening shows fresh numbers in one cheap pass.
    private let sampler = PulseSampler()
    private let lifetime = FeatureSamplingLifetime()
    private let readSample: (@Sendable () -> MachinePulse)?
    private let samplingAllowed: @MainActor () -> Bool
    private let observe: @MainActor (MachinePulse) -> Void
    private let actionsAllowed: @MainActor () -> Bool
    private let reviewDelay: TimeInterval
    private let readActionReview: (@Sendable (Hog, MachinePulse, PulseActionReview.Action) -> PulseActionReview)?
    private let recordActionReview: @Sendable (PulseActionReview) -> Void

    init(readSample: (@Sendable () -> MachinePulse)? = nil, samplingQueue: DispatchQueue? = nil, samplingAllowed: @escaping @MainActor () -> Bool = { true },
         reviewDelay: TimeInterval = 5,
         readActionReview: (@Sendable (Hog, MachinePulse, PulseActionReview.Action) -> PulseActionReview)? = nil,
         recordActionReview: @escaping @Sendable (PulseActionReview) -> Void = { $0.record() },
         observe: @escaping @MainActor (MachinePulse) -> Void = { _ in }, actionsAllowed: @escaping @MainActor () -> Bool = { true }) {
        self.readSample = readSample
        self.observe = observe; self.actionsAllowed = actionsAllowed
        self.samplingAllowed = samplingAllowed
        self.reviewDelay = reviewDelay
        self.readActionReview = readActionReview
        self.recordActionReview = recordActionReview
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

    @MainActor func start() {
        guard samplingAllowed(), timer == nil else { return }
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

    @MainActor func stop() {
        #if DEBUG
        Self.trace("stop", lifetime.current())
        #endif
        lifetime.stop(); timer?.cancel(); timer = nil
    }

    /// Cards showing the pulse (panel and main window): sampling runs while at least one is visible.
    private var holders = 0
    var samplingActive: Bool { timer != nil }
    var holderCount: Int { holders }
    @MainActor func hold() { holders += 1; if holders == 1 { start() } }
    @MainActor func release() { holders = max(0, holders - 1); if holders == 0 { stop() } }

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
            MainActor.assumeIsolated { self.observe(pulse) }
        }
    }

    /// Recheck the entire process inventory; an idle reopened app can fall out of the busiest list.
    @MainActor func review(_ hog: Hog, before: MachinePulse, action: PulseActionReview.Action) {
        let id = UUID(); reviewID = id
        pendingActionReviews.insert(id)
        actionFeedback = tr("Checking the effect of the action…")
        queue.asyncAfter(deadline: .now() + reviewDelay) { [weak self] in
            guard let self else { return }
            let result: PulseActionReview
            if let read = self.readActionReview { result = read(hog, before, action) }
            else {
                let after = self.sampler.sample()
                let all = MachinePulse.group(ProcessTable.current(.init(cpu: false)).entries, byMemory: true, limit: nil)
                result = PulseActionReview(action: action, target: hog, before: before, after: after,
                                           afterTarget: PulseActionReview.findTarget(hog, in: all), inventoryAvailable: !all.isEmpty)
            }
            self.recordActionReview(result)
            DispatchQueue.main.async {
                defer { self.finishActionReview(id) }
                guard self.reviewID == id else { return }
                self.actionFeedback = MachinePulse.sentences(result.summary, result.detail)
            }
            self.sample()
        }
    }

    @MainActor private func finishActionReview(_ id: UUID) {
        pendingActionReviews.remove(id)
        guard pendingActionReviews.isEmpty else { return }
        let waiting = actionReviewWaiters; actionReviewWaiters = []
        for continuation in waiting { continuation.resume() }
    }

    @MainActor func finishStoppingFeature() async {
        // A queue fence alone misses work scheduled with asyncAfter but not enqueued yet.
        // Cancellation must still yield until the promised journal has actually finished.
        if actionReviewInFlight { await withCheckedContinuation { actionReviewWaiters.append($0) } }
        await withCheckedContinuation { done in queue.async { done.resume() } }
        if timer == nil { current = nil }
    }

    /// Apps are asked to quit (they may save or refuse); other processes get SIGTERM.
    @MainActor func quit(_ hog: Hog) {
        guard samplingAllowed(), actionsAllowed() else { return }
        quitProblem = nil
        guard hog.quittable, !quitting.contains(hog.id) else { return }
        let before = current
        let baseline = current?.hogs.first { $0.id == hog.id }
        var requested=false
        if let path=hog.app {
            guard let app=NSWorkspace.shared.runningApplications.first(where:{$0.bundleURL?.standardizedFileURL.path==path}),
                  let expected=hog.applicationIdentity,expected.pid==app.processIdentifier else {
                quitProblem=tr("%1$@ changed or exited since the reading. Check again before stopping it.",hog.name);return
            }
            let outcome=ProcessActionGate.attempt(expected,allowApplication:true){_ in app.terminate()}
            requested=outcome == .requested
            if !requested {quitProblem=outcome == .declined ? tr("%1$@ did not accept the quit request. Check its dialogs.",hog.name):tr("System processes, AI agent sessions and Thermo itself cannot be stopped here.")}
        } else {
            let identities=hog.processIdentities ?? []
            var skipped=identities.count != hog.pids.count
            for expected in identities where hog.pids.contains(expected.pid) {
                let outcome=ProcessActionGate.attempt(expected,allowApplication:false){value in kill(value.pid,SIGTERM)==0}
                requested=requested || outcome == .requested
                if outcome != .requested {skipped=true}
            }
            if skipped {quitProblem=tr("%1$@ changed or exited since the reading. Check again before stopping it.",hog.name)}
        }
        guard requested else{return}
        if let before, let baseline { review(baseline, before: before, action: .quit) }
        else { actionFeedback = tr("The follow-up readings cannot be compared. Check again.") }
        quitting.insert(hog.id)
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.sample() }
        let identities = hog.app == nil ? hog.processIdentities ?? [] : hog.applicationIdentity.map { [$0] } ?? []
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            let stillRunning = identities.contains { ProcessTable.identity($0.pid)==$0 }
            DispatchQueue.main.async {
                self?.quitting.remove(hog.id)
                if stillRunning {
                    self?.quitProblem = tr("%1$@ is still running. Check any save dialogs before trying again.", hog.name)
                }
            }
            self?.sample()
        }
    }

    /// One process the user picked by hand on the Memory page. Unlike `quit`, which acts on a
    /// whole row, this never widens beyond the single checked identity.
    struct SingleStop: Identifiable, Equatable {
        var identity: ProcessIdentity
        var name: String
        /// The process belongs to an app bundle (a helper, or with `force` the app itself).
        var application = false
        /// An AI agent session: allowed here only because the user chose this one process.
        var agentSession = false
        /// SIGKILL straight away instead of SIGTERM.
        var force = false
        var memoryKB = 0
        var id: String { "\(identity.pid)|\(force)" }
    }
    enum SingleStopResult: Equatable { case stopped, killed, stillRunning, changed, protected, notDelivered }

    /// PIDs being ended right now, so their rows show progress instead of a second button.
    @Published private(set) var ending: Set<Int32> = []
    /// Asked to stop and still running after the wait: the page offers to force it.
    @Published private(set) var unresponsive: SingleStop?

    @MainActor func dismissUnresponsive() { unresponsive = nil }

    @MainActor func end(_ stop: SingleStop, grace: TimeInterval = 5,
                        perform: @escaping @Sendable (SingleStop, TimeInterval) -> SingleStopResult = { SystemPulse.perform($0, grace: $1) },
                        record: @escaping @Sendable (SingleStop, SingleStopResult) -> Void = { SystemPulse.record($0, $1) }) {
        guard samplingAllowed(), actionsAllowed() else { return }
        let pid = stop.identity.pid
        guard !ending.contains(pid) else { return }
        quitProblem = nil; actionFeedback = nil; unresponsive = nil
        ending.insert(pid)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = perform(stop, grace)
            record(stop, result)
            DispatchQueue.main.async {
                guard let self else { return }
                self.ending.remove(pid)
                let freed = MemoryFormat.string(kibibytes: stop.memoryKB)
                switch result {
                case .stopped: self.actionFeedback = tr("%1$@ (PID %2$@) stopped after being asked; about %3$@ freed.", stop.name, String(pid), freed)
                case .killed: self.actionFeedback = tr("%1$@ (PID %2$@) was forced to quit; about %3$@ freed.", stop.name, String(pid), freed)
                case .stillRunning:
                    if stop.force { self.quitProblem = tr("%1$@ (PID %2$@) is still running.", stop.name, String(pid)) }
                    else { self.unresponsive = stop }
                case .changed: self.quitProblem = tr("PID %1$@ is no longer the process that was checked; nothing was sent.", String(pid))
                case .protected: self.quitProblem = tr("System processes and Thermo itself cannot be stopped.")
                case .notDelivered: self.quitProblem = tr("The signal could not be delivered to PID %1$@.", String(pid))
                }
            }
            self?.queue.async { self?.sample() }
        }
    }

    /// Every process of one command-line program, across its project rows. Built only from rows
    /// that could be ended on their own: agent sessions, apps and protected rows are never in it.
    struct ProgramStop: Identifiable, Equatable {
        struct Row: Equatable { var project: String?; var identities: [ProcessIdentity] }
        var id: String
        var name: String
        var rows: [Row]
        /// Processes of the same program that stay because their row is protected or an agent session.
        var leftAlone = 0
        var memoryKB = 0
        var identities: [ProcessIdentity] { rows.flatMap(\.identities) }
    }
    struct ProgramStopResult: Equatable { var ended = 0, stillRunning = 0, skipped = 0 }

    @Published private(set) var endingPrograms: Set<String> = []

    @MainActor func endAll(_ stop: ProgramStop, grace: TimeInterval = 5,
                           perform: @escaping @Sendable (ProgramStop, TimeInterval) -> ProgramStopResult = { SystemPulse.perform($0, grace: $1) },
                           record: @escaping @Sendable (ProgramStop, ProgramStopResult) -> Void = { SystemPulse.record($0, $1) }) {
        guard samplingAllowed(), actionsAllowed(), !endingPrograms.contains(stop.id), !stop.identities.isEmpty else { return }
        quitProblem = nil; actionFeedback = nil; unresponsive = nil
        endingPrograms.insert(stop.id)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = perform(stop, grace)
            record(stop, result)
            DispatchQueue.main.async {
                guard let self else { return }
                self.endingPrograms.remove(stop.id)
                if result.ended > 0 {
                    self.actionFeedback = tr("%1$@ of %2$@ %3$@ processes stopped after being asked.",
                                             String(result.ended), String(stop.identities.count), stop.name)
                }
                var problems: [String] = []
                if result.stillRunning > 0 { problems.append(tr("%1$@ are still running; end them one at a time to force them.", String(result.stillRunning))) }
                if result.skipped > 0 { problems.append(tr("%1$@ changed or exited since the reading and were not signalled.", String(result.skipped))) }
                if !problems.isEmpty { self.quitProblem = problems.joined(separator: " ") }
            }
            self?.queue.async { self?.sample() }
        }
    }

    /// Each identity goes through the gate by itself, with no agent or application capability.
    nonisolated static func perform(_ stop: ProgramStop, grace: TimeInterval,
                                    signal: (Int32, Int32) -> Bool = { kill($0, $1) == 0 }) -> ProgramStopResult {
        var result = ProgramStopResult()
        var asked: [ProcessIdentity] = []
        for identity in stop.identities {
            if ProcessActionGate.attempt(identity, allowApplication: false, request: { signal($0.pid, SIGTERM) }) == .requested { asked.append(identity) }
            else { result.skipped += 1 }
        }
        let deadline = Date().addingTimeInterval(grace)
        func alive() -> Int { asked.filter { ProcessTable.identity($0.pid) == $0 }.count }
        while Date() < deadline, alive() > 0 { usleep(100_000) }
        result.stillRunning = alive()
        result.ended = asked.count - result.stillRunning
        return result
    }

    nonisolated static func record(_ stop: ProgramStop, _ result: ProgramStopResult) {
        guard result.ended + result.stillRunning > 0 else { return }
        OperationJournal.record(OperationRecord(feature: "pulse", action: "end", subject: stop.name,
                                                items: [.init(target: "\(stop.name) · \(stop.identities.count) PIDs",
                                                              bytes: 0, status: result.stillRunning == 0 && result.skipped == 0 ? "done" : "failed",
                                                              detail: "ended \(result.ended), stillRunning \(result.stillRunning), skipped \(result.skipped)")]))
    }

    /// Rechecks the identity, sends one signal through the gate and waits for the process to go.
    nonisolated static func perform(_ stop: SingleStop, grace: TimeInterval,
                                    signal: (Int32, Int32) -> Bool = { kill($0, $1) == 0 }) -> SingleStopResult {
        let identity = stop.identity
        let outcome = ProcessActionGate.attempt(identity, allowApplication: stop.application, allowAgentSession: stop.agentSession) { value in
            signal(value.pid, stop.force ? SIGKILL : SIGTERM)
        }
        switch outcome {
        case .requested: break
        case .declined: return .notDelivered
        case .protected: return .protected
        case .changed, .unavailable: return .changed
        }
        let deadline = Date().addingTimeInterval(stop.force ? min(grace, 3) : grace)
        while Date() < deadline, ProcessTable.identity(identity.pid) == identity { usleep(100_000) }
        if ProcessTable.identity(identity.pid) == identity { return .stillRunning }
        return stop.force ? .killed : .stopped
    }

    nonisolated static func record(_ stop: SingleStop, _ result: SingleStopResult) {
        guard result != .changed, result != .protected else { return }
        let done = result == .stopped || result == .killed
        OperationJournal.record(OperationRecord(feature: "pulse", action: "end", subject: stop.name,
                                                items: [.init(target: "\(stop.name) · PID \(stop.identity.pid)",
                                                              bytes: done ? Int64(stop.memoryKB) * 1024 : 0,
                                                              status: done ? "done" : "failed", detail: "\(result)")]))
    }

    static func canSignal(_ expected: ProcessIdentity, current: ProcessIdentity?, uid: UInt32 = getuid(), me: Int32 = getpid()) -> Bool {
        ProcessActionGate.identityAllows(expected,current:current,uid:uid,me:me)
    }

    /// The app being restarted, while it quits and comes back.
    @Published private(set) var restarting: String?
    /// Why the last restart did not go as planned.
    @Published var restartProblem: String?

    /// Quit like ⌘Q, wait until every process of it has gone, then open it again; it restores its
    /// own windows and tabs. Gives up (and says so) if it is still running after a minute.
    @MainActor func restart(_ hog: Hog) {
        guard samplingAllowed(), actionsAllowed() else { return }
        guard hog.quittable, restarting == nil, !quitting.contains(hog.id) else { return }
        guard let path = hog.app,
              let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.standardizedFileURL.path == path })
        else { return }
        guard let expected=hog.applicationIdentity,expected.pid==app.processIdentifier,
              ProcessActionGate.validate(expected,allowApplication:true) == .allowed(expected) else {
            restartProblem = tr("%1$@ changed or exited since the reading. Check again before stopping it.", hog.name)
            return
        }
        let before = current
        let baseline = current?.hogs.first { $0.id == hog.id }
        restarting = hog.name
        restartProblem = nil
        actionFeedback = nil
        reviewID = UUID()
        var identities=hog.processIdentities ?? []
        guard Set(hog.pids).isSubset(of:Set(identities.map(\.pid))) else {
            restarting=nil;restartProblem=tr("%1$@ changed or exited since the reading. Check again before stopping it.",hog.name);return
        }
        if !identities.contains(expected){identities.append(expected)}
        let checkedIdentities=identities,name=hog.name
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
            let outcome=DispatchQueue.main.sync {ProcessActionGate.attempt(expected,allowApplication:true){_ in app.terminate()}}
            guard outcome == .requested else {
                DispatchQueue.main.async {self?.restarting=nil;self?.restartProblem=tr("%1$@ changed or exited since the reading. Check again before stopping it.",name)}
                return
            }
            let deadline=Date().addingTimeInterval(60)
            func alive()->Bool{checkedIdentities.contains{ProcessTable.identity($0.pid)==$0}}
            while Date()<deadline,alive(){usleep(250_000)}
            let gone = !alive()
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
