import Foundation

/// Closing is immediate, even while the network queue is blocked in kernel I/O.
public final class AWDLConnectionOwner: @unchecked Sendable {
    public let id=UUID().uuidString
    private let lock=NSLock()
    private var closed=false
    public init() {}
    public var isClosed: Bool { lock.lock();defer { lock.unlock() };return closed }
    @discardableResult public func close() -> Bool {
        lock.lock();defer { lock.unlock() };guard !closed else { return false };closed=true;return true
    }
}

/// Owns all AWDL state on its own queue; fan sampling must never wait on it.
public final class AWDLHelperCoordinator: @unchecked Sendable {
    private let queue=DispatchQueue(label:"dev.thermo.helper.network",qos:.utility)
    private var controller: AWDLSessionController!
    private var timer: DispatchSourceTimer?
    private var removalToken: String?
    private var stopping=false
    private var activeOwner: AWDLConnectionOwner?
    public init(make: @escaping @Sendable () -> AWDLSessionController = {
        AWDLSessionController(io:.system,store:AWDLLeaseFile().io)
    },tickInterval: TimeInterval = 1) {
        queue.async { [self] in
            self.controller=make()
            let timer=DispatchSource.makeTimerSource(queue:self.queue)
            timer.schedule(deadline:.now()+max(0.05,tickInterval),repeating:max(0.05,tickInterval))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                if let owner=self.activeOwner,owner.isClosed { self.controller.disconnected(owner:owner.id);self.activeOwner=nil }
                self.controller.tick()
            }
            self.timer=timer;timer.resume()
        }
    }
    deinit { timer?.cancel() }
    public func begin(owner: AWDLConnectionOwner,seconds: Int,sessionID: String,reply: @escaping @Sendable (String?) -> Void) {
        queue.async {
            guard !owner.isClosed,!self.stopping,self.removalToken == nil else { reply("AWDL connection is closed or helper is preparing to stop");return }
            do {
                try self.controller.begin(owner:owner.id,seconds:seconds,sessionID:sessionID)
                self.activeOwner=owner
                guard !owner.isClosed else {
                    self.controller.disconnected(owner:owner.id);self.activeOwner=nil
                    reply("AWDL connection closed during start");return
                }
                reply(nil)
            } catch { reply(error.localizedDescription) }
        }
    }
    public func end(owner: AWDLConnectionOwner,reply: @escaping @Sendable (String?) -> Void) {
        queue.async {
            do { try self.controller.end(owner:owner.id);self.activeOwner=nil;reply(nil) }
            catch { reply(error.localizedDescription) }
        }
    }
    public func state(owner: AWDLConnectionOwner,reply: @escaping @Sendable (Data) -> Void) {
        queue.async {
            reply((try? PolicyCoding.encoder().encode(self.controller.snapshot(for:owner.isClosed ? nil : owner.id))) ?? Data())
        }
    }
    public func disconnected(owner: AWDLConnectionOwner) {
        owner.close()
        queue.async {
            self.controller.disconnected(owner:owner.id)
            if self.activeOwner?.id == owner.id { self.activeOwner=nil }
            if self.removalToken?.hasPrefix(owner.id+":") == true { self.removalToken=nil }
        }
    }
    public func prepareRemoval(_ prepare: Bool,token: String,owner: AWDLConnectionOwner,reply: @escaping @Sendable (String?) -> Void) {
        queue.async {
            guard !prepare || !owner.isClosed else { reply("AWDL connection is closed");return }
            guard self.removalToken == nil || self.removalToken == token else { reply("Another connection is preparing helper removal");return }
            if prepare {
                self.removalToken=token;self.activeOwner=nil
                let confirmed=self.controller.recover(reason:"prepareRemoval")
                if owner.isClosed { self.removalToken=nil }
                reply(confirmed ? nil : self.controller.snapshot().error ?? "AWDL restoration is unconfirmed")
            } else { self.removalToken=nil;reply(nil) }
        }
    }
    public func shutdown(reason: String,reply: @escaping @Sendable (Bool) -> Void) {
        queue.async { self.stopping=true;self.activeOwner=nil;reply(self.controller.recover(reason:reason)) }
    }
}

/// Independent recovery operations all run, even if a different subsystem fails.
public enum HelperRecoveryFanout {
    public typealias Operation = (@escaping @Sendable (String?) -> Void) -> Void
    public static func run(_ operations: [Operation],reply: @escaping @Sendable (String?) -> Void) {
        let result=Replies()
        let group=DispatchGroup()
        for operation in operations {
            group.enter();let once=Once()
            operation { error in once.run { result.add(error);group.leave() } }
        }
        group.notify(queue:.global(qos:.utility)) { reply(result.message) }
    }
    private final class Replies: @unchecked Sendable {
        let lock=NSLock();var errors: [String]=[]
        func add(_ error: String?) { guard let error else { return };lock.lock();errors.append(error);lock.unlock() }
        var message: String? { lock.lock();defer { lock.unlock() };return errors.isEmpty ? nil : errors.sorted().joined(separator:"; ") }
    }
}
