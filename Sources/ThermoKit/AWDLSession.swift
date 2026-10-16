import CSMC
import Darwin
import Foundation

public struct AWDLInterfaceState: Codable, Equatable, Sendable {
    public var index: UInt32
    public var up: Bool
    public init(index: UInt32, up: Bool) { self.index=index;self.up=up }
}

public struct AWDLRestoreRecord: Codable, Equatable, Sendable {
    public let version: Int
    public let index: UInt32
    public let wasUp: Bool
    public let bootSession: String
    public init(index: UInt32,wasUp: Bool,bootSession: String) { version=1;self.index=index;self.wasUp=wasUp;self.bootSession=bootSession }
    public var valid: Bool { version == 1 && index > 0 && UUID(uuidString:bootSession) != nil }
}

public struct AWDLInterfaceIO {
    public var read: () throws -> AWDLInterfaceState?
    public var write: (UInt32,Bool) throws -> Void
    public init(read: @escaping () throws -> AWDLInterfaceState?,write: @escaping (UInt32,Bool) throws -> Void) { self.read=read;self.write=write }
    public static var system: Self { .init(read:{
        var index: UInt32=0,up=false
        let status=thermo_awdl_read(&index,&up)
        if status == ENXIO || status == ENODEV { return nil }
        guard status == 0,index > 0 else { throw AWDLError("AWDL read failed (errno \(status))") }
        return .init(index:index,up:up)
    },write:{ index,up in
        let status=thermo_awdl_set_up(index,up)
        guard status == 0 else { throw AWDLError("AWDL change failed (errno \(status))") }
    }) }
}

public struct AWDLLeaseIO {
    public var load: () throws -> AWDLRestoreRecord?
    public var save: (AWDLRestoreRecord) throws -> Void
    public var clear: (AWDLRestoreRecord) throws -> Void
    public init(load: @escaping () throws -> AWDLRestoreRecord?,save: @escaping (AWDLRestoreRecord) throws -> Void,clear: @escaping (AWDLRestoreRecord) throws -> Void) {
        self.load=load;self.save=save;self.clear=clear
    }
}

public struct AWDLError: LocalizedError {
    public var message: String
    public init(_ message: String) { self.message=message }
    public var errorDescription: String? { message }
}

public enum AWDLSystemClock {
    /// Advances through sleep; a sleeping Mac must not extend a low-latency lease.
    public static func now() -> TimeInterval {
        var info=mach_timebase_info_data_t();mach_timebase_info(&info)
        return Double(mach_continuous_time())*Double(info.numer)/Double(info.denom)/1e9
    }
    public static func bootSession() -> String? {
        var bytes=[CChar](repeating:0,count:128),size=128
        guard sysctlbyname("kern.bootsessionuuid",&bytes,&size,nil,0) == 0,
              let end=bytes.firstIndex(of:0) else { return nil }
        let value=String(decoding:bytes.prefix(end).map { UInt8(bitPattern:$0) },as:UTF8.self)
        return UUID(uuidString:value)?.uuidString
    }
}

public struct AWDLSessionState: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case idle, active, recovering, blocked }
    public var phase: Phase = .blocked
    public var interface: AWDLInterfaceState?
    public var interfaceQueryComplete = false
    public var remainingSeconds: Int?
    public var ownedByCaller = false
    public var lastEndReason: String?
    public var error: String?
    public init() {}
}

/// Serialized by its caller on a dedicated helper network queue, independently
/// of fan safety sampling. Persistence precedes the
/// first interface write. A restarted helper always restores, never resumes a lease.
public final class AWDLSessionController {
    private let io: AWDLInterfaceIO
    private let store: AWDLLeaseIO
    private let boot: () -> String?
    private let clock: () -> TimeInterval
    private var record: AWDLRestoreRecord?
    private var owner: String?
    private var began: TimeInterval?
    private var deadline: TimeInterval?
    private var state=AWDLSessionState()
    private func sameBoot(_ expected: String) -> Bool {
        guard let current=boot(),let a=UUID(uuidString:current),let b=UUID(uuidString:expected) else { return false }
        return a == b
    }
    public init(io: AWDLInterfaceIO,store: AWDLLeaseIO,boot: @escaping () -> String? = AWDLSystemClock.bootSession,
                clock: @escaping () -> TimeInterval = AWDLSystemClock.now) {
        self.io=io;self.store=store;self.boot=boot;self.clock=clock
        _=recover(reason:"helperStarted")
    }
    private func observe() throws -> AWDLInterfaceState? {
        do { let value=try io.read();state.interface=value;state.interfaceQueryComplete=true;return value }
        catch { state.interface=nil;state.interfaceQueryComplete=false;throw error }
    }
    public func snapshot(for caller: String? = nil) -> AWDLSessionState {
        do {
            _=try observe()
            if state.phase == .idle || state.phase == .active { state.error=nil }
        } catch { state.error=error.localizedDescription }
        var result=state
        result.ownedByCaller=owner != nil && owner == caller
        if state.phase == .active,let deadline {
            let now=clock(),left=deadline-now
            result.remainingSeconds=left.isFinite ? Int(max(0,min(3600,ceil(left)))) : 0
        }
        return result
    }
    public func begin(owner: String,seconds: Int) throws {
        guard UUID(uuidString:owner) != nil,(60...3600).contains(seconds) else { throw AWDLError("Invalid AWDL session request") }
        guard state.phase != .active else { throw AWDLError("An AWDL session is already active") }
        guard recover(reason:"beforeStart") else { throw AWDLError(state.error ?? "AWDL recovery is pending") }
        guard let boot=boot(),UUID(uuidString:boot) != nil,let before=try observe(),before.index > 0 else { throw AWDLError("AWDL identity is unavailable") }
        let now=clock();guard now.isFinite,now >= 0 else { throw AWDLError("AWDL clock is unavailable") }
        let saved=AWDLRestoreRecord(index:before.index,wasUp:before.up,bootSession:boot)
        // No network write is allowed until the recovery record is durable.
        do { try store.save(saved) } catch { state.phase = .blocked;state.error=error.localizedDescription;throw error }
        record=saved;self.owner=owner;began=now;deadline=now+Double(seconds);state.phase = .recovering
        do {
            guard sameBoot(boot),let current=try observe(),current.index == before.index else { throw AWDLError("AWDL identity changed before start") }
            if current.up { try io.write(before.index,false) }
            guard sameBoot(boot),let after=try observe(),after.index == before.index,!after.up else { throw AWDLError("AWDL down state could not be confirmed") }
            state.phase = .active;state.error=nil;state.lastEndReason=nil
        } catch {
            let failure=error
            _=recover(reason:"startFailed")
            throw failure
        }
    }
    public func end(owner: String) throws {
        guard self.owner == nil || self.owner == owner else { throw AWDLError("Another connection owns this AWDL session") }
        guard recover(reason:"stopped") else { throw AWDLError(state.error ?? "AWDL restoration is pending") }
    }
    public func disconnected(owner: String) { if self.owner == owner { _=recover(reason:"connectionClosed") } }
    public func tick() {
        guard state.phase == .active else {
            if state.phase == .recovering || state.phase == .blocked { _=recover(reason:"recoveryRetry") };return
        }
        let now=clock()
        guard now.isFinite,let began,now >= began,let deadline,now < deadline else { _=recover(reason:"expired");return }
        do {
            guard let record,sameBoot(record.bootSession),let current=try observe(),current.index == record.index,!current.up else {
                _=recover(reason:"interfaceChanged");return
            }
        } catch { _=recover(reason:"readFailed") }
    }
    /// Used on helper restart, stop, removal and process exit. Interface replacement
    /// retires the old lease without writing to a different interface instance.
    @discardableResult public func recover(reason: String) -> Bool {
        owner=nil;began=nil;deadline=nil;state.phase = .recovering
        do {
            if record == nil { record=try store.load() }
            guard let saved=record else { state.phase = .idle;state.error=nil;return true }
            guard saved.valid,let currentBoot=boot(),UUID(uuidString:currentBoot) != nil else { throw AWDLError("AWDL recovery identity is invalid or unavailable") }
            var endReason=reason
            if UUID(uuidString:currentBoot) != UUID(uuidString:saved.bootSession) { endReason="bootChanged" }
            else if let before=try observe(),before.index == saved.index {
                if before.up != saved.wasUp { try? io.write(saved.index,saved.wasUp) }
                guard sameBoot(saved.bootSession),let after=try observe(),after.index == saved.index,after.up == saved.wasUp else {
                    throw AWDLError("AWDL original state could not be confirmed")
                }
            } else { endReason="interfaceReplaced" }
            try store.clear(saved)
            record=nil;state.phase = .idle;state.error=nil;state.lastEndReason=endReason
            return true
        } catch { state.phase = record == nil ? .blocked : .recovering;state.error=error.localizedDescription;return false }
    }
}
