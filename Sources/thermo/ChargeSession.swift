import Foundation
import ThermoKit

enum ChargeSignals {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func cancel() { lock.lock(); value = true; lock.unlock() }
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
    static func run<T>(_ body: (() -> Bool) throws -> T) throws -> T {
        let flag = Flag()
        let registered = DispatchGroup()
        let signals: [Int32] = [SIGINT, SIGTERM, SIGHUP]
        let previous = signals.map { signal($0, SIG_IGN) }
        let sources = signals.map { number -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .utility))
            // Swift and lock operations run on a dispatch queue, never inside
            // an asynchronous POSIX signal handler.
            registered.enter(); source.setRegistrationHandler { registered.leave() }
            source.setEventHandler { flag.cancel() }; source.resume(); return source
        }
        defer { sources.forEach { $0.cancel() }; for (number, handler) in zip(signals, previous) { signal(number, handler) } }
        guard registered.wait(timeout: .now() + 5) == .success else { throw BatteryGateError("Charging signal handlers could not be registered; no policy was started") }
        return try body { flag.cancelled }
    }
}
struct ChargeBackend {
    var read: () throws -> BatteryChargeState
    var set: (BatteryChargePolicy, String) throws -> Void
    var reset: () -> Void
    var record: (String, String, String?) -> Void = { _, _, _ in }
}
struct ChargeSessionFailure: LocalizedError, CustomStringConvertible {
    let message: String
    let recoveryConfirmed: Bool
    var errorDescription: String? { message }
    var description: String { message }
}

/// Foreground ownership and recovery policy, independently testable from signal
/// installation and launchd. A changed public session must never be stopped.
struct ChargeForegroundSession {
    let backend: ChargeBackend
    static func ended(_ state: BatteryChargeState) -> Bool {
        state.policy == .off && state.phase == .off && state.ownership == .none && !state.ownedByCaller && state.sessionID == nil
    }
    func run(policy: BatteryChargePolicy, id: String = UUID().uuidString,
             interrupted: () -> Bool, wait: () -> Void, emit: (BatteryChargeState) throws -> Void) throws {
        guard policy != .off, UUID(uuidString: id) != nil else { throw BatteryChargeClientError.notStarted("Invalid foreground charging request") }
        defer { backend.reset() }
        guard !interrupted() else { return }
        var initialRequestPending = true
        do {
            try backend.set(policy, id)
            initialRequestPending = false
            backend.record("charging-" + policy.rawValue, "done", nil)
            while !interrupted() {
                let state = try backend.read(); try emit(state)
                if Self.ended(state) {
                    if let error = state.error { throw BatteryGateError(error) }
                    backend.record("charging-recovery", "done", nil); return
                }
                if state.policy != .off, let current = state.sessionID, current != id, !state.ownedByCaller {
                    backend.record("charging-recovery", "done", "Previous session ended; another process owns the current policy"); return
                }
                guard state.ownedByCaller, state.sessionID == id else { throw BatteryGateError(state.error ?? "Charging connection ownership changed; recovery must be checked") }
                wait()
            }
            try backend.set(.off, id)
            let state = try backend.read(); try emit(state)
            guard Self.ended(state) else { throw BatteryGateError("Thermo charging recovery is not confirmed") }
            backend.record("charging-recovery", "done", nil)
        } catch {
            let original = error.localizedDescription
            backend.record(initialRequestPending ? "charging-" + policy.rawValue : "charging-session", "failed", original)
            if initialRequestPending, error is BatteryChargeClientError { throw error }
            var confirmed = false
            do {
                var state = try backend.read()
                if state.ownedByCaller, state.sessionID == id {
                    try backend.set(.off, id); state = try backend.read()
                }
                confirmed = Self.ended(state) || (state.policy != .off && state.sessionID != nil && state.sessionID != id && !state.ownedByCaller)
                try emit(state)
            } catch {}
            backend.record("charging-recovery", confirmed ? "done" : "failed", original)
            throw ChargeSessionFailure(message: original + (confirmed ? "; this charging session has ended" : "; recovery is unconfirmed; check charge status before retrying"), recoveryConfirmed: confirmed)
        }
    }
}
