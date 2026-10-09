import Foundation
import ThermoKit

// Root LaunchDaemon: the only process that writes the SMC. Owns fan policies and
// runs the control loop; returns every fan to automatic control on start, on exit,
// and when the hottest compute sensor reaches FanPolicyEngine.safetyCeiling.

func log(_ s: String) {
    var t = time(nil)
    var tmv = tm()
    localtime_r(&t, &tmv)
    var buf = [CChar](repeating: 0, count: 32)
    strftime(&buf, buf.count, "%Y-%m-%d %H:%M:%S", &tmv)
    FileHandle.standardError.write("\(String(cString: buf)) thermo-helper: \(s)\n".data(using: .utf8)!)
}

guard getuid() == 0 else {
    log("must run as root (installed by `thermo helper install`)")
    exit(1)
}

final class Controller {
    let queue = DispatchQueue(label: "dev.thermo.helper.control")
    let sampler: Sampler
    let writer: FanWriter
    var engine = FanPolicyEngine()
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
    }

    func start() {
        queue.sync {
            writer.setAllAuto()
            log("started; \(sampler.discovery.fans.count) fan(s), \(sampler.discovery.sensors.filter(\.essential).count) control sensors; fans set to auto")
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
                log(String(format: "FAILSAFE: %.1f °C ≥ %.0f °C; all policies cleared, fans on auto", t, FanPolicyEngine.safetyCeiling))
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
            if policy == .auto { try writer.setAuto(id) }
            log("fan \(id): \(policy.description)")
        }
        if !engine.isActive && sampler.discovery.fanTestKey { writer.setAllAuto() }
        tick()   // apply now rather than at the next timer fire
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

let delegate = ListenerDelegate(Service(controller))
let listener = NSXPCListener(machServiceName: HelperConstants.machService)
listener.delegate = delegate
listener.resume()
dispatchMain()
