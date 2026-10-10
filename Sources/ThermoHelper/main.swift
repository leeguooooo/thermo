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
    let queue = DispatchQueue(label: "dev.thermo.helper.control")
    let sampler: Sampler
    let writer: FanWriter
    var engine: FanPolicyEngine
    /// Last RPM written per fan, for hysteresis and ramping.
    var written: [Int: Double] = [:]
    var timer: DispatchSourceTimer?

    static let interval: TimeInterval = 2
    static let hysteresis = 50.0
    /// Max decrease per tick, so fans spin down gently instead of hunting.
    static let rampDown = 400.0

    init() throws {
        sampler = try Sampler(scope: .essential, useCache: false)
        sampler.parts = [.temperatures, .fans]
        sampler.fanLimitRefresh = 10
        writer = FanWriter(smc: sampler.smc, discovery: sampler.discovery)
        // Apple Silicon is the platform with the Ftst unlock key.
        engine = FanPolicyEngine(limits: .forHardware(appleSilicon: sampler.discovery.fanTestKey))
    }

    func start() {
        queue.sync {
            writer.setAllAuto()
            log("started; \(sampler.discovery.fans.count) fan(s), \(sampler.discovery.sensors.filter(\.essential).count) control sensors; fans set to auto")
            // What the user chose survives restarts (updates, reboots); the next tick applies it,
            // with the over-temperature protection as always.
            let saved = PolicyStore.load()
            for (fan, policy) in saved.sorted(by: { $0.key < $1.key })
            where sampler.discovery.fans.contains(where: { $0.index == fan }) && policy != .auto {
                engine.set(policy, for: fan)
                log("fan \(fan): restored \(policy.description)")
            }
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func shutdown(reason: String) {
        queue.sync {
            writer.setAllAuto()
            log("\(reason); fans returned to auto")
        }
    }

    /// Must run on `queue`.
    func tick() {
        guard engine.isActive else { return }
        let snapshot = sampler.sample()
        for action in engine.tick(snapshot) {
            switch action {
            case .failsafe(let t):
                writer.setAllAuto()
                written.removeAll()
                log(String(format: "FAILSAFE: %.1f °C ≥ %.0f °C; fans on auto, policies suspended until below %.0f °C for %d s",
                           t, engine.limits.ceiling, engine.limits.resumeBelow, engine.limits.resumeTicks * Int(Self.interval)))
            case .resume(let t):
                log(String(format: "cooled to %.1f °C; resuming fan policies", t))
            case .auto(let fan):
                try? writer.setAuto(fan)
                written[fan] = nil
            case .manual(let fan, var rpm):
                if let last = written[fan] {
                    if abs(rpm - last) < Self.hysteresis { continue }
                    if rpm < last { rpm = max(rpm, last - Self.rampDown) }
                }
                do {
                    written[fan] = try writer.setManual(fan, rpm: rpm)
                } catch {
                    log("fan \(fan): write failed: \(error)")
                }
            }
        }
    }

    func setPolicy(_ policy: FanPolicy, fan: Int) throws {
        let ids = fan == -1 ? sampler.discovery.fans.map(\.index) : [fan]
        for id in ids {
            guard sampler.discovery.fans.contains(where: { $0.index == id }) else { throw FanControlError.noSuchFan(id) }
            engine.set(policy, for: id)
            written[id] = nil
            if policy == .auto {
                do {
                    try writer.setAuto(id)
                } catch {
                    // Never leave a fan stranded in manual mode: fall back to a full reset.
                    log("fan \(id): auto failed (\(error)); resetting all fans")
                    writer.setAllAuto()
                }
            }
            log("fan \(id): \(policy.description)")
        }
        if !engine.isActive && sampler.discovery.fanTestKey { writer.setAllAuto() }
        do { try PolicyStore.save(engine.policies) } catch { log("could not save policies: \(error)") }
    }
}

final class Service: NSObject, ThermoHelperProtocol {
    let controller: Controller
    init(_ c: Controller) { controller = c }

    func version(reply: @escaping (String) -> Void) { reply(HelperConstants.version) }

    func setPolicy(fan: Int, policy: Data, reply: @escaping (String?) -> Void) {
        controller.queue.async {
            do {
                let p = try PolicyCoding.decoder().decode(FanPolicy.self, from: policy)
                if case .fixed(let r) = p, !(r >= 0) { throw FanControlError.helper("invalid rpm") }
                try self.controller.setPolicy(p, fan: fan)
                reply(nil)
                // Apply right away, but after replying: on Apple Silicon the first
                // manual write waits for the Ftst unlock (2+ s), longer than a client
                // should block on an XPC reply.
                self.controller.queue.async { self.controller.tick() }
            } catch {
                reply("\(error)")
            }
        }
    }

    func policies(reply: @escaping (Data) -> Void) {
        controller.queue.async {
            reply((try? PolicyCoding.encoder().encode(self.controller.engine.policies)) ?? Data("{}".utf8))
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service: Service
    init(_ s: Service) { service = s }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        c.setCodeSigningRequirement(HelperConstants.clientRequirement)
        c.exportedInterface = NSXPCInterface(with: ThermoHelperProtocol.self)
        c.exportedObject = service
        c.resume()
        return true
    }
}

let controller: Controller
do {
    controller = try Controller()
} catch {
    log("cannot open SMC: \(error)")
    exit(1)
}
controller.start()

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        controller.shutdown(reason: "signal \(sig)")
        exit(0)
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
            controller.shutdown(reason: "executable replaced (update)")
            exit(0)
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
            controller.shutdown(reason: "updated itself to \(v) from \(source)")
            exit(0)
        }
    }
    t.resume()
    selfUpdateTimer = t
}

let delegate = ListenerDelegate(Service(controller))
let listener = NSXPCListener(machServiceName: HelperConstants.machService)
listener.delegate = delegate
listener.resume()
dispatchMain()
