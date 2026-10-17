import Foundation
import ThermoKit

// Root LaunchDaemon: the only process that writes the SMC. Owns fan policies and
// runs the control loop; returns every fan to automatic control on start, on exit,
// and while the hottest compute sensor stays above the platform's safety ceiling
// (policies are suspended, then resume once it has cooled; see SafetyLimits).

func log(_ s: String) {
    var t = time(nil)
    var tmv = tm()
    localtime_r(&t, &tmv)
    var buf = [CChar](repeating: 0, count: 32)
    strftime(&buf, buf.count, "%Y-%m-%d %H:%M:%S", &tmv)
    FileHandle.standardError.write("\(String(cString: buf)) thermo-helper: \(s)\n".data(using: .utf8)!)
}

// Asked by a running helper deciding whether this binary is a newer build (see HelperSelfUpdate).
if CommandLine.arguments.contains("--print-version") {
    print(ThermoVersion.string)
    exit(0)
}

guard getuid() == 0 else {
    log("must run as root (installed by `thermo helper install`)")
    exit(1)
}

final class Controller {
    let queue: DispatchQueue
    let sampler: Sampler
    let writer: FanWriter
    var engine: FanPolicyEngine
    /// Last RPM written per fan, for hysteresis and ramping.
    var written: [Int: Double] = [:]
    var pendingRecovery: FanAutoRecoveryReport?
    var controlError: String?
    var observations: [Int: FanControlObservation] = [:]
    let removalGuard: HelperRemovalGuard
    var timer: DispatchSourceTimer?
    let lidAwake: LidAwakeController
    var lidTimer: DispatchSourceTimer?
    var stopping=false
    var shutdownSleepPending=false

    static let interval: TimeInterval = 2
    static let hysteresis = 50.0
    /// Max decrease per tick, so fans spin down gently instead of hunting.
    static let rampDown = 400.0

    init(queue: DispatchQueue,removalGuard: HelperRemovalGuard) throws {
        self.queue=queue;self.removalGuard=removalGuard
        sampler = try Sampler(scope: .essential, useCache: false)
        sampler.parts = [.temperatures, .fans]
        sampler.fanLimitRefresh = 10
        writer = FanWriter(smc: sampler.smc, discovery: sampler.discovery)
        // Apple Silicon is the platform with the Ftst unlock key.
        engine = FanPolicyEngine(limits: .forHardware(appleSilicon: sampler.discovery.fanTestKey),
                                 requiresGPU: sampler.discovery.sensors.contains { $0.essential && $0.known && $0.quantity == .temperature && $0.group == .gpu })
        // The fan limits follow the Ftst key, which some Apple Silicon Macs lack (then the stricter Intel
        // ceiling applies to fans, which is safe). Lid-awake follows the actual CPU instead, or it would
        // turn itself off at 85 °C during ordinary work on those Macs.
        lidAwake = LidAwakeController(limits: .forHardware(appleSilicon: LidAwakeController.appleSilicon), log: log)
    }

    func start() {
        restoreFans(reason: "helper started")
        // Keep-awake-with-the-lid-closed never survives a restart (crash, update, reboot).
        lidAwake.restoreOriginal(reason: "helper started")
        log("started; \(sampler.discovery.fans.count) fan(s), \(sampler.discovery.sensors.filter(\.essential).count) control sensors")
        // What the user chose survives restarts (updates, reboots); the next tick applies it,
        // with the over-temperature protection as always.
        let saved = PolicyStore.load()
        for (fan, policy) in saved.sorted(by: { $0.key < $1.key })
        where !removalGuard.isPreparing && sampler.discovery.fans.contains(where: { $0.index == fan }) && policy != .auto {
            engine.set(policy, for: fan)
            log("fan \(fan): restored \(policy.description)")
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        let lid = DispatchSource.makeTimerSource(queue: queue)
        lid.schedule(deadline: .now() + 10, repeating: 10, leeway: .seconds(1))
        lid.setEventHandler { [weak self] in self?.lidTick() }
        lid.resume()
        lidTimer = lid
    }

    /// Must run on `queue`. The safety rules run whether or not the lid is closed: a hot Mac is hot either way.
    func lidTick() {
        guard !stopping else { return }
        guard lidAwake.state.armed else {
            lidAwake.tick(hottest: nil, battery: nil, lidClosed: SleepSwitch.lidClosed())
            return
        }
        let s = sampler.sample()
        lidAwake.tick(hottest: engine.observeControlTemperature(s), battery: Battery.read(), lidClosed: SleepSwitch.lidClosed())
    }

    func shutdown(reason: String) -> Bool {
        stopping=true
        let report = restoreFans(reason: reason)
        do { try lidAwake.restoreOriginalChecked(reason:reason);shutdownSleepPending=false;return report.confirmed }
        catch { shutdownSleepPending=true;log("sleep restoration failed: \(error)");return false }
    }

    @discardableResult
    func restoreFans(reason: String) -> FanAutoRecoveryReport {
        let report = writer.setAllAuto()
        pendingRecovery = report.confirmed ? nil : report
        written.removeAll()
        observations.removeAll()
        if report.confirmed {
            for fan in sampler.discovery.fans { observations[fan.index] = .init(mode: .automatic) }
        }
        log("\(reason); \(report.summary)")
        if !report.requestErrors.isEmpty { log("reset requests: " + report.requestErrors.joined(separator: "; ")) }
        return report
    }

    /// Must run on `queue`.
    func tick() {
        if stopping {
            if pendingRecovery != nil { restoreFans(reason:"shutdown automatic control retry") }
            if shutdownSleepPending {
                do { try lidAwake.restoreOriginalChecked(reason:"shutdown retry");shutdownSleepPending=false }
                catch { log("sleep restoration retry failed: \(error)") }
            }
            return
        }
        if pendingRecovery != nil, !restoreFans(reason: "retry automatic control").confirmed { return }
        guard !removalGuard.isPreparing else { return }
        // A failed manual request stays suspended until an explicit policy change.
        // Automatic recovery must not silently retry the same faulty manual write.
        guard controlError == nil else { return }
        guard engine.isActive else { return }
        let snapshot = sampler.sample()
        for action in engine.tick(snapshot) {
            switch action {
            case .temperatureUnavailable:
                let restored = restoreFans(reason: "required CPU/GPU temperature unavailable; under-cooling policies suspended")
                if !restored.confirmed { return }
            case .failsafe(let t):
                let restored = restoreFans(reason: "thermal failsafe")
                log(String(format: "FAILSAFE: %.1f °C ≥ %.0f °C; policies suspended until below %.0f °C for %d s",
                           t, engine.limits.ceiling, engine.limits.resumeBelow, engine.limits.resumeTicks * Int(Self.interval)))
                if !restored.confirmed { return }
            case .resume(let t):
                log(String(format: "cooled to %.1f °C; resuming fan policies", t))
            case .auto(let fan):
                do { try writer.setAuto(fan) } catch {
                    if !restoreFans(reason: "fan \(fan) auto failed: \(error)").confirmed { return }
                }
                written[fan] = nil
                observations[fan] = .init(mode: .automatic)
            case .manual(let fan, var rpm):
                do {
                    if let last = written[fan] {
                        if abs(rpm - last) < Self.hysteresis {
                            let target = try writer.verifyManual(fan, rpm: last)
                            observations[fan] = .init(mode: .manual, target: target)
                            continue
                        }
                        if rpm < last { rpm = max(rpm, last - Self.rampDown) }
                    }
                    written[fan] = try writer.setManual(fan, rpm: rpm)
                    observations[fan] = .init(mode: .manual, target: written[fan])
                } catch {
                    log("fan \(fan): write failed: \(error)")
                    controlError = "fan \(fan): manual control failed: \(error)"
                    restoreFans(reason: "manual control failed")
                    return
                }
            }
        }
    }

    var controlState: FanControlState {
        FanControlState(policies: engine.policies, observations: observations, suspended: engine.suspended, suspensionReason: engine.suspensionReason,
                        failure: pendingRecovery?.summary ?? controlError)
    }

    func setPolicy(_ policy: FanPolicy, fan: Int) throws {
        guard !stopping else { throw FanControlError.helper("helper is stopping") }
        guard !removalGuard.isPreparing else { throw FanControlError.helper("helper is preparing for removal; fan policy changes are blocked") }
        try policy.validate()
        if policy != .auto, pendingRecovery != nil, !restoreFans(reason: "before policy change").confirmed {
            throw FanControlError.helper(pendingRecovery?.summary ?? "automatic control unconfirmed")
        }
        let ids = fan == -1 ? sampler.discovery.fans.map(\.index) : [fan]
        for id in ids { guard sampler.discovery.fans.contains(where: { $0.index == id }) else { throw FanControlError.noSuchFan(id) } }
        var next = engine
        for id in ids { next.set(policy, for: id) }
        try FanPolicyCommit.apply(policy,
            save: { try PolicyStore.save(next.policies) },
            commit: {
                self.engine = next
                for id in ids { self.written[id] = nil; self.observations[id] = nil }
            },
            applyAutomatic: {
                var errors: [String] = []
                for id in ids {
                    do {
                        try self.writer.setAuto(id)
                        self.observations[id] = .init(mode: .automatic)
                    } catch { errors.append(String(describing: error)) }
                }
                if !self.engine.isActive && self.sampler.discovery.fanTestKey {
                    let report = self.restoreFans(reason: "last policy returned to auto")
                    if !report.confirmed { errors.append(report.summary) }
                }
                if !errors.isEmpty { throw FanControlError.helper(errors.joined(separator: "; ")) }
            },
            restoreAll: { self.restoreFans(reason: "policy change recovery") },
            recordFault: { self.controlError = $0 })
        for id in ids { log("fan \(id): requested \(policy.description)") }
        controlError = nil
    }
}

let fans=FanHost()
let network=AWDLHelperCoordinator()
let charging=BatteryHelperCoordinator()

func shutdownAll(reason: String) -> Bool {
    let group=DispatchGroup(),result=ShutdownResult()
    group.enter();fans.shutdown(reason:reason) { ok in result.record(ok);group.leave() }
    group.enter();network.shutdown(reason:reason) { ok in result.record(ok);group.leave() }
    group.enter();charging.shutdown(reason:reason) { ok in result.record(ok);group.leave() }
    guard group.wait(timeout:.now()+12) == .success else { log("shutdown recovery timed out; durable network/charging recovery remains for restart");return false }
    return result.confirmed
}

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        let recovery = shutdownAll(reason: "signal \(sig)")
        exit(recovery ? 0 : 1)
    }
    src.resume()
    signalSources.append(src)
}

// When the app is updated (Sparkle replaces the bundle, or `thermo helper install` overwrites the
// binary), exit so launchd restarts us from the new executable. Fans go back to auto on the way out,
// like any other helper stop.
var binaryWatch: DispatchSourceFileSystemObject?
if let path = Bundle.main.executablePath ?? CommandLine.arguments.first {
    let fd = open(path, O_EVTONLY)
    if fd >= 0 {
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.delete, .rename, .write], queue: .main)
        src.setEventHandler {
            let recovery = shutdownAll(reason: "executable replaced (update)")
            exit(recovery ? 0 : 1)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        binaryWatch = src
    }
}

// Password installs: follow the app's own helper (see HelperSelfUpdate). Checked at start and
// every 30 s; a swap exits, and launchd's KeepAlive starts the new binary.
var selfUpdateTimer: DispatchSourceTimer?
if let i = CommandLine.arguments.firstIndex(of: "--source"), i + 1 < CommandLine.arguments.count,
   let team = CodeSignature.teamIdentifier() {
    let source = CommandLine.arguments[i + 1]
    let installed = CommandLine.arguments[0]
    var lastRejection = ""
    let t = DispatchSource.makeTimerSource(queue: .main)
    t.schedule(deadline: .now() + 5, repeating: 30, leeway: .seconds(5))
    t.setEventHandler {
        switch HelperSelfUpdate.update(from: source, to: installed, team: team, current: ThermoVersion.string) {
        case .unchanged where !lastRejection.isEmpty:
            // The source became usable again (or matches); say so once, to time the next update.
            log("self-update: \(source) is current")
            lastRejection = ""
        case .unchanged:
            break
        case .rejected(let why):
            if why != lastRejection { log("self-update skipped: \(why)"); lastRejection = why }
        case .updated(let v):
            let recovery = shutdownAll(reason: "updated itself to \(v) from \(source)")
            exit(recovery ? 0 : 1)
        }
    }
    t.resume()
    selfUpdateTimer = t
}

let delegate = ListenerDelegate(fans:fans,network:network,charging:charging)
let listener = NSXPCListener(machServiceName: HelperConstants.machService)
listener.delegate = delegate
listener.resume()
dispatchMain()
