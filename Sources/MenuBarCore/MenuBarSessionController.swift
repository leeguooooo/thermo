import Foundation

@MainActor public protocol MenuBarVisibilitySession: AnyObject {
    func activate(completion: @escaping @MainActor (String?) -> Void)
    /// Returns a diagnostic if restoring the session could not be requested.
    func invalidate() -> String?
}

/// The asynchronous system callback is not authority to hide after a newer
/// request, timeout, sleep or quit. Every handle remains owned until invalidated.
@MainActor public final class MenuBarSessionController {
    public enum State: Equatable { case visible, applying, applied, failed(String) }
    public private(set) var state: State = .visible
    public var didChange: (@MainActor (State) -> Void)?
    private var active: (MenuBarConfiguration, any MenuBarVisibilitySession)?
    private var pending: (MenuBarConfiguration, any MenuBarVisibilitySession)?
    private var recoverySessions: [ObjectIdentifier: any MenuBarVisibilitySession] = [:]
    private var generation: UInt64 = 0
    private var timeout: Task<Void, Never>?
    private let timeoutNanoseconds: UInt64
    private let make: @MainActor (MenuBarConfiguration) throws -> any MenuBarVisibilitySession

    public init(timeoutNanoseconds: UInt64 = 4_000_000_000,
                make: @escaping @MainActor (MenuBarConfiguration) throws -> any MenuBarVisibilitySession) {
        self.timeoutNanoseconds = timeoutNanoseconds
        self.make = make
    }

    public func apply(_ configuration: MenuBarConfiguration?) {
        guard let configuration else { restore(); return }
        // A failed restoration retains handles for recovery. They must not be
        // mistaken for an already-applied configuration, or overlap a new one.
        if case .failed = state {
            restore()
            guard state == .visible else { return }
        }
        if pending?.0 == configuration || (pending == nil && active?.0 == configuration) { return }
        generation &+= 1
        let request = generation
        timeout?.cancel(); timeout = nil
        if let pending {
            if let error = pending.1.invalidate() { fail(error); return }
            self.pending = nil
        }
        do {
            let session = try make(configuration)
            pending = (configuration, session)
            update(.applying)
            session.activate { [weak self, session] error in
                guard let self else { _ = session.invalidate(); return }
                self.finished(request: request, session: session, error: error)
            }
            // A fake or future backend may complete synchronously.
            guard generation == request, pending != nil else { return }
            let delay = timeoutNanoseconds
            timeout = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: delay) } catch { return }
                guard let self, self.generation == request, self.pending != nil else { return }
                self.fail("Menu bar visibility request timed out.")
            }
        } catch { fail(error.localizedDescription) }
    }

    public func restore() {
        generation &+= 1
        timeout?.cancel(); timeout = nil
        let errors = releaseSessions()
        update(errors.isEmpty ? .visible : .failed(errors.joined(separator: "\n")))
    }

    private func finished(request: UInt64, session: any MenuBarVisibilitySession, error: String?) {
        guard generation == request, let pending, pending.1 === session else {
            // Invalidating before a late success may not prevent activation.
            if let error = session.invalidate() {
                recoverySessions[ObjectIdentifier(session)] = session
                fail(error)
            }
            return
        }
        if let error { fail(error); return }
        timeout?.cancel(); timeout = nil
        if let old = active, let error = old.1.invalidate() { fail(error); return }
        active = pending
        self.pending = nil
        update(.applied)
    }

    private func fail(_ message: String) {
        generation &+= 1
        timeout?.cancel(); timeout = nil
        let errors = releaseSessions()
        update(.failed(([message] + errors).joined(separator: "\n")))
    }

    private func releaseSessions() -> [String] {
        // Keep failed handles for a later explicit recovery attempt.
        var errors: [String] = []
        if let pending {
            if let error = pending.1.invalidate() { errors.append(error) } else { self.pending = nil }
        }
        if let active {
            if let error = active.1.invalidate() { errors.append(error) } else { self.active = nil }
        }
        for (identity, session) in recoverySessions {
            if let error = session.invalidate() { errors.append(error) } else { recoverySessions[identity] = nil }
        }
        return errors
    }

    private func update(_ state: State) { self.state = state; didChange?(state) }
}
