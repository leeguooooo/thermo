import Foundation
import ThermoKit

private func failureMessage(_ error: Error) -> String { (error as? FanControlError)?.description ?? error.localizedDescription }
// Foundation XPC reply blocks are designed to be called from an asynchronous queue.
private struct XPCReply<Value: Sendable>: @unchecked Sendable { let call: (Value) -> Void }
private func rpcReply<Value: Sendable>(_ callback: @escaping (Value) -> Void) -> @Sendable (Value) -> Void {
    let box=XPCReply(call:callback);return { box.call($0) }
}

final class ShutdownResult: @unchecked Sendable {
    private let lock=NSLock();private var ok=true
    func record(_ value: Bool) { lock.lock();ok = ok && value;lock.unlock() }
    var confirmed: Bool { lock.lock();defer { lock.unlock() };return ok }
}

/// Initialization and retries happen away from the listener and network queue.
final class FanHost: @unchecked Sendable {
    let queue=DispatchQueue(label:"dev.thermo.helper.control")
    private let removal=HelperRemovalGuard()
    private var controller: Controller?
    private var issue="fan controller is initializing"
    private var retry: DispatchSourceTimer?
    private var stopping=false
    private let make: (DispatchQueue,HelperRemovalGuard) throws -> Controller
    private let fallbackSleep: LidAwakeController?
    private let saveAutomatic: () throws -> Void
    init(make: @escaping (DispatchQueue,HelperRemovalGuard) throws -> Controller = { try Controller(queue:$0,removalGuard:$1) },
         fallbackSleep: LidAwakeController? = LidAwakeController(limits:.forHardware(appleSilicon:LidAwakeController.appleSilicon),log:log),
         saveAutomatic: @escaping () throws -> Void = { try PolicyStore.save([:]) }) {
        self.make=make;self.fallbackSleep=fallbackSleep;self.saveAutomatic=saveAutomatic
        queue.async { [self] in
            self.initialize()
            let timer=DispatchSource.makeTimerSource(queue:self.queue)
            timer.schedule(deadline:.now()+15,repeating:15)
            timer.setEventHandler { [weak self] in
                guard let self,!self.stopping,self.controller == nil else { return };self.initialize()
            }
            self.retry=timer;timer.resume()
        }
    }
    deinit { retry?.cancel() }
    private func initialize() {
        do { let c=try make(queue,removal);c.start();controller=c;issue="" }
        catch {
            let next="fan controller unavailable: \(error)"
            if next != issue { log(next) };issue=next
            do { try fallbackSleep?.restoreOriginalChecked(reason:"SMC unavailable") }
            catch { log("sleep restoration while SMC unavailable failed: \(error)") }
        }
    }
    func perform(_ body: @escaping (Controller) -> Void,unavailable: @escaping (String) -> Void) {
        queue.async {
            guard !self.stopping else { unavailable("helper is stopping");return }
            if let controller=self.controller { body(controller) } else { unavailable(self.issue) }
        }
    }
    func prepare(_ prepare: Bool,token: String,owner: AWDLConnectionOwner,reply: @escaping @Sendable (String?) -> Void) {
        queue.async {
            guard !prepare || !owner.isClosed else { reply("connection is closed");return }
            do {
                if prepare {
                    try self.removal.prepare(token:token,
                        clearPolicies:{ self.controller?.engine.clear();self.controller?.written.removeAll() },
                        savePolicies:self.saveAutomatic,
                        restoreFans:{ self.controller?.restoreFans(reason:"prepare removal") ?? FanAutoRecoveryReport(unconfirmed:[self.issue],requestErrors:[]) },
                        restoreSleep:{
                            if let c=self.controller { try c.lidAwake.restoreOriginalChecked(reason:"prepare removal") }
                            else { try self.fallbackSleep?.restoreOriginalChecked(reason:"prepare removal") }
                        })
                    self.controller?.controlError=nil
                } else { try self.removal.cancel(token:token) }
                if owner.isClosed { self.removal.abandon(ownerPrefix:owner.id+":") }
                reply(nil)
            } catch {
                if owner.isClosed { self.removal.abandon(ownerPrefix:owner.id+":") }
                reply(failureMessage(error))
            }
        }
    }
    func disconnected(owner: AWDLConnectionOwner) { queue.async { self.removal.abandon(ownerPrefix:owner.id+":") } }
    func shutdown(reason: String,reply: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            self.stopping=true
            if let c=self.controller { reply(c.shutdown(reason:reason)) }
            else {
                do { try self.fallbackSleep?.restoreOriginalChecked(reason:reason) } catch { log("sleep restoration failed: \(error)") }
                reply(false)
            }
        }
    }
}

final class Service: NSObject, ThermoHelperProtocol {
    let fans: FanHost
    let network: AWDLHelperCoordinator
    let charging: BatteryHelperCoordinator?
    let owner=AWDLConnectionOwner()
    private let legacyChargingSessionID = UUID().uuidString
    init(fans: FanHost,network: AWDLHelperCoordinator,charging: BatteryHelperCoordinator? = nil) { self.fans=fans;self.network=network;self.charging=charging }
    deinit { if owner.close() { network.disconnected(owner:owner);fans.disconnected(owner:owner);charging?.disconnected(owner:owner) } }
    func disconnected() {
        guard owner.close() else { return };network.disconnected(owner:owner);fans.disconnected(owner:owner);charging?.disconnected(owner:owner)
    }
    func version(reply: @escaping (String) -> Void) { reply(HelperConstants.version) }
    func beginAWDL(seconds: Int,sessionID: String,reply: @escaping (String?) -> Void) { network.begin(owner:owner,seconds:seconds,sessionID:sessionID,reply:rpcReply(reply)) }
    func endAWDL(reply: @escaping (String?) -> Void) { network.end(owner:owner,reply:rpcReply(reply)) }
    func awdlState(reply: @escaping (Data) -> Void) { network.state(owner:owner,reply:rpcReply(reply)) }
    func setBatteryChargePolicy(_ policy: String, reply: @escaping (String?) -> Void) {
        setBatteryChargePolicy(policy, sessionID: legacyChargingSessionID, reply: reply)
    }
    func setBatteryChargePolicy(_ policy: String, sessionID: String, reply: @escaping (String?) -> Void) {
        guard let value = BatteryChargePolicy(rawValue: policy) else { reply("Invalid charging policy"); return }
        guard let charging else { reply("Charging controller is unavailable"); return }
        charging.setPolicy(value, owner: owner, sessionID: sessionID, reply: rpcReply(reply))
    }
    func batteryChargeState(reply: @escaping (Data) -> Void) {
        guard let charging else { var value = BatteryChargeState(); value.error = "Charging controller is unavailable"; reply((try? PolicyCoding.encoder().encode(value)) ?? Data()); return }
        charging.state(owner: owner, reply: rpcReply(reply))
    }
    func prepareRemoval(_ prepare: Bool,token: String,reply: @escaping (String?) -> Void) {
        guard !token.isEmpty,token.utf8.count <= 128 else { reply("invalid removal token");return }
        let scoped=owner.id+":"+token
        HelperRecoveryFanout.run([
            { done in self.fans.prepare(prepare,token:scoped,owner:self.owner,reply:done) },
            { done in self.network.prepareRemoval(prepare,token:scoped,owner:self.owner,reply:done) },
            { done in
                if let charging = self.charging { charging.prepareRemoval(prepare, token: scoped, owner: self.owner, reply: done) }
                else { done(nil) }
            }
        ],reply:rpcReply(reply))
    }
    func setPolicy(fan: Int,policy: Data,reply: @escaping (String?) -> Void) {
        fans.perform({ c in
            do {
                let value=try PolicyCoding.decoder().decode(FanPolicy.self,from:policy)
                try c.setPolicy(value,fan:fan);reply(nil);c.queue.async { c.tick() }
            } catch { reply(failureMessage(error)) }
        },unavailable:reply)
    }
    func policies(reply: @escaping (Data) -> Void) {
        fans.perform({ c in
            reply((try? FanPolicyReply.encode(c.engine.policies,recovery:c.pendingRecovery,controlError:c.controlState.legacyError)) ?? Data())
        },unavailable:{ error in reply((try? FanPolicyReply.encode([:],recovery:nil,controlError:error)) ?? Data()) })
    }
    func fanControlState(reply: @escaping (Data) -> Void) {
        fans.perform({ c in reply((try? PolicyCoding.encoder().encode(c.controlState)) ?? Data()) },unavailable:{ error in
            reply((try? PolicyCoding.encoder().encode(FanControlState(policies:[:],failure:error))) ?? Data())
        })
    }
    func setLidAwake(_ on: Bool,reply: @escaping (String?) -> Void) { setLidAwake(on,heatGuard:true,reply:reply) }
    func setLidAwake(_ on: Bool,heatGuard: Bool,reply: @escaping (String?) -> Void) {
        fans.perform({ c in
            guard !c.removalGuard.isPreparing else { reply("helper is preparing for removal");return }
            do { try c.lidAwake.set(on,heatGuard:heatGuard);reply(nil) } catch { reply(failureMessage(error)) }
        },unavailable:reply)
    }
    func lidAwakeState(reply: @escaping (Data) -> Void) {
        fans.perform({ c in
            var value=c.lidAwake.state;value.lidClosed=SleepSwitch.lidClosed()
            reply((try? PolicyCoding.encoder().encode(value)) ?? Data())
        },unavailable:{ _ in reply(Data()) })
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let fans: FanHost
    let network: AWDLHelperCoordinator
    let charging: BatteryHelperCoordinator
    init(fans: FanHost,network: AWDLHelperCoordinator,charging: BatteryHelperCoordinator) { self.fans=fans;self.network=network;self.charging=charging }
    func listener(_ listener: NSXPCListener,shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(HelperConstants.clientRequirement)
        connection.exportedInterface=NSXPCInterface(with:ThermoHelperProtocol.self)
        let service=Service(fans:fans,network:network,charging:charging)
        connection.exportedObject=service
        connection.invalidationHandler={ service.disconnected() }
        connection.interruptionHandler={ service.disconnected() }
        connection.resume();return true
    }
}
