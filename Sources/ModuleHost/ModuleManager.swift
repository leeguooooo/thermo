import AppKit
import Darwin
import ExtensionFoundation
import ExtensionKit
import ModuleKit

public enum ModuleError: Error, CustomStringConvertible, Equatable {
    case unknown(String), off(String), notInstalled(String), foreign(String), interface(Int), exited(String), failed(String)
    public var description: String {
        switch self {
        case .unknown(let id): return "no module \(id)"
        case .off(let id): return "module \(id) is switched off"
        case .notInstalled(let id): return "module \(id) is not registered with the system"
        case .foreign(let path): return "refused a module process outside this app: \(path)"
        case .interface(let n): return "module was built for interface \(n)"
        case .exited(let id): return "module \(id) exited"
        case .failed(let text): return text
        }
    }
}

/// The kernel's side of every module: finds the modules inside this app, starts and stops their
/// processes as `ModuleLifecycle` says, and is the only way to reach them.
@MainActor public final class ModuleManager {
    public struct Status: Sendable, Equatable {
        public var manifest: ModuleManifest
        public var enabled: Bool
        public var phase: ModuleLifecycle.Phase
        public var pid: pid_t?
        public var crashes: Int
        /// Whether the kernel has a wake-up pending for this module.
        public var scheduled: Bool
        public var uses: Int
    }

    /// One module scene embedded in the kernel's window. Keeps the module running while attached and
    /// comes back by itself after the module process was restarted.
    @MainActor public final class Scene: NSObject, EXHostViewControllerDelegate {
        public let controller = EXHostViewController()
        public let module: String
        public let scene: String
        public private(set) var active = false
        /// Called on the main thread when the module's UI appears or goes away.
        public var onChange: ((Bool) -> Void)?
        init(module: String, scene: String) { self.module = module; self.scene = scene; super.init(); controller.delegate = self }
        public func hostViewControllerDidActivate(_ viewController: EXHostViewController) { active = true; onChange?(true) }
        public func hostViewControllerWillDeactivate(_ viewController: EXHostViewController, error: (any Error)?) { active = false; onChange?(false) }
    }

    private final class Slot {
        let module: InstalledModule
        var lifecycle: ModuleLifecycle
        var candidates: [AppExtensionIdentity] = []
        var identity: AppExtensionIdentity?
        var process: AppExtensionProcess?
        var connection: NSXPCConnection?
        var pid: pid_t?
        var exit: DispatchSourceProcess?
        var wake: DispatchWorkItem?
        var scenes: [Scene] = []
        var waiters: [(Result<Void, ModuleError>) -> Void] = []
        /// Bumped for every start, so a late answer about an old process is ignored.
        var generation = 0
        init(_ module: InstalledModule, lifecycle: ModuleLifecycle) { self.module = module; self.lifecycle = lifecycle }
    }

    public let app: URL
    public private(set) var problems: [String] = []
    /// Called on the main thread after any module changed state.
    public var onChange: ((String) -> Void)?
    /// What the kernel answers when a module asks for something. The default refuses everything.
    public var kernel: (ModuleManifest) -> KernelXPC = { _ in RefusingKernel() }
    /// How a stop went, for diagnostics: "invalidated", "terminated" or "killed".
    public private(set) var lastStop: [String: String] = [:]
    /// Why the last start of a module failed.
    public private(set) var lastFailure: [String: String] = [:]

    private var slots: [String: Slot] = [:]
    private var order: [String] = []
    private let timing: ModuleLifecycle.Timing
    private let extensionsPath: String

    public init(app: URL = Bundle.main.bundleURL, timing: ModuleLifecycle.Timing = .init()) {
        self.app = app; self.timing = timing
        extensionsPath = app.resolvingSymlinksInPath().appendingPathComponent("Contents/Extensions").path + "/"
    }

    /// Reads the modules inside this app and asks the system for their identities. Nothing is started.
    public func load(enabled: (ModuleManifest) -> Bool) async {
        let found = ModuleBundles.installed(in: app)
        problems = found.problems
        for module in found.modules where slots[module.manifest.id] == nil {
            slots[module.manifest.id] = Slot(module, lifecycle: ModuleLifecycle(launch: module.manifest.launch, enabled: false, timing: timing))
            order.append(module.manifest.id)
        }
        await identify()
        for id in order where enabled(slots[id]!.module.manifest) { setEnabled(id, true) }
    }

    /// The system may know the same module from several copies of the app, so every identity with a
    /// matching bundle id is kept and the right one is chosen when its process is seen.
    private func identify() async {
        guard !slots.isEmpty else { return }
        let ids = Set(slots.keys)
        let search = Task { () -> [AppExtensionIdentity] in
            var last: [AppExtensionIdentity] = []
            do {
                for await batch in try AppExtensionIdentity.matching(appExtensionPointIDs: ModuleBundles.extensionPoint) {
                    last = batch
                    if ids.isSubset(of: Set(batch.map(\.bundleIdentifier))) || Task.isCancelled { break }
                }
            } catch {}
            return last
        }
        let limit = Task { try? await Task.sleep(nanoseconds: 5_000_000_000); search.cancel() }
        let all = await search.value
        limit.cancel()
        for (id, slot) in slots {
            slot.candidates = all.filter { $0.bundleIdentifier == id }
            if slot.candidates.isEmpty { problems.append("\(id): not registered with the system") }
        }
    }

    /// How many registrations the system has for each module id; more than one means other copies of the app.
    public var registrations: [String: Int] { slots.mapValues { $0.candidates.count } }

    public var modules: [Status] { order.compactMap { status($0) } }

    public func status(_ id: String) -> Status? {
        guard let slot = slots[id] else { return nil }
        let l = slot.lifecycle
        return Status(manifest: slot.module.manifest, enabled: l.enabled, phase: l.phase, pid: slot.pid, crashes: l.crashes,
                      scheduled: slot.wake != nil, uses: l.uses)
    }

    /// The entries the kernel shows: those of modules that are on. A module that is off has none.
    public var activeEntries: [(module: String, entry: ModuleManifest.Entry)] {
        order.flatMap { id -> [(module: String, entry: ModuleManifest.Entry)] in
            guard let slot = slots[id], slot.lifecycle.enabled else { return [] }
            return slot.module.manifest.entries.map { (id, $0) }
        }
    }

    public func usage(_ id: String) -> ModuleUsage? { slots[id]?.pid.flatMap { ModuleUsage.read($0) } }

    public func setEnabled(_ id: String, _ on: Bool) {
        guard let slot = slots[id] else { return }
        if !on {
            for scene in slot.scenes { scene.controller.configuration = nil }
            fail(slot, .off(id))
        }
        send(on ? .enable : .disable, to: slot)
    }

    /// Runs one of the module's commands, starting the module if needed.
    public func run(_ id: String, command: String, arguments: Data = Data("{}".utf8)) async throws -> Data {
        guard let slot = slots[id] else { throw ModuleError.unknown(id) }
        guard slot.lifecycle.enabled else { throw ModuleError.off(id) }
        send(.acquire, to: slot)
        defer { send(.release, to: slot) }
        try await ready(slot)
        guard let connection = slot.connection else { throw ModuleError.exited(id) }
        let generation = slot.generation
        do {
            return try await withCheckedThrowingContinuation { (k: CheckedContinuation<Data, Error>) in
                let once = Once()
                let proxy = connection.remoteObjectProxyWithErrorHandler { _ in once.run { k.resume(throwing: ModuleError.exited(id)) } } as? ModuleXPC
                guard let proxy else { once.run { k.resume(throwing: ModuleError.exited(id)) }; return }
                proxy.run(command, arguments: arguments) { data, problem in
                    once.run {
                        if let data { k.resume(returning: data) } else { k.resume(throwing: ModuleError.failed(problem ?? "no answer")) }
                    }
                }
            }
        } catch ModuleError.exited {
            // The connection broke mid-command. That can be known before the exit is, and a module
            // nobody can talk to is of no use: count it as gone now and make sure it is.
            if slot.generation == generation, let pid = slot.pid {
                gone(slot)
                if Self.path(of: pid).hasPrefix(extensionsPath) { kill(pid, SIGKILL) }
            }
            throw ModuleError.exited(id)
        }
    }

    /// Embeds one of the module's scenes. The module stays running until `detach`.
    public func attach(_ id: String, scene name: String) throws -> Scene {
        guard let slot = slots[id] else { throw ModuleError.unknown(id) }
        guard slot.lifecycle.enabled else { throw ModuleError.off(id) }
        let scene = Scene(module: id, scene: name)
        slot.scenes.append(scene)
        send(.acquire, to: slot)
        if slot.lifecycle.phase == .running { show(scene, slot) }
        return scene
    }

    public func detach(_ scene: Scene) {
        guard let slot = slots[scene.module], let index = slot.scenes.firstIndex(where: { $0 === scene }) else { return }
        slot.scenes.remove(at: index)
        scene.controller.configuration = nil
        send(.release, to: slot)
    }

    private func show(_ scene: Scene, _ slot: Slot) {
        guard let identity = slot.identity else { return }
        scene.controller.configuration = .init(appExtension: identity, sceneID: scene.scene)
    }

    // MARK: Lifecycle

    private func send(_ event: ModuleLifecycle.Event, to slot: Slot) {
        let effects = slot.lifecycle.handle(event, now: ProcessInfo.processInfo.systemUptime)
        for effect in effects {
            switch effect {
            case .start: start(slot)
            case .stop: stop(slot)
            }
        }
        schedule(slot)
        onChange?(slot.module.manifest.id)
    }

    private func schedule(_ slot: Slot) {
        slot.wake?.cancel(); slot.wake = nil
        guard let due = slot.lifecycle.deadline else { return }
        let item = DispatchWorkItem { [weak self, weak slot] in
            guard let self, let slot else { return }
            slot.wake = nil
            self.send(.tick, to: slot)
        }
        slot.wake = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, due - ProcessInfo.processInfo.systemUptime) + 0.01, execute: item)
    }

    private func ready(_ slot: Slot) async throws {
        if slot.lifecycle.phase == .running, slot.connection != nil { return }
        let result: Result<Void, ModuleError> = await withCheckedContinuation { k in slot.waiters.append { k.resume(returning: $0) } }
        try result.get()
    }

    private func fail(_ slot: Slot, _ error: ModuleError) {
        let waiting = slot.waiters; slot.waiters = []
        for waiter in waiting { waiter(.failure(error)) }
    }

    private func start(_ slot: Slot) {
        slot.generation += 1
        let generation = slot.generation, id = slot.module.manifest.id
        Task { @MainActor in
            do {
                try await self.launch(slot, generation: generation)
                guard slot.generation == generation else { return }
                self.send(.started, to: slot)
                // Switched off while it was starting: `started` asked for a stop, nobody may use it.
                guard slot.lifecycle.phase == .running else { return }
                let waiting = slot.waiters; slot.waiters = []
                for waiter in waiting { waiter(.success(())) }
                for scene in slot.scenes { self.show(scene, slot) }
            } catch {
                guard slot.generation == generation else { return }
                self.release(slot)
                self.lastFailure[id] = "\(error)"
                self.fail(slot, (error as? ModuleError) ?? .failed("\(id): \(error)"))
                self.send(.startFailed, to: slot)
            }
        }
    }

    private func launch(_ slot: Slot, generation: Int) async throws {
        let id = slot.module.manifest.id
        let tries = slot.identity.map { [$0] } ?? slot.candidates
        guard !tries.isEmpty else { throw ModuleError.notInstalled(id) }
        var refused: ModuleError = .notInstalled(id)
        for identity in tries {
            let process = try await AppExtensionProcess(configuration: .init(appExtensionIdentity: identity, onInterruption: {}))
            let connection = try process.makeXPCConnection()
            connection.remoteObjectInterface = ModuleXPCInterfaces.module
            connection.exportedInterface = ModuleXPCInterfaces.kernel
            connection.exportedObject = kernel(slot.module.manifest)
            connection.resume()
            // The pid is only known once the connection has carried a message.
            let built: Int
            do { built = try await Self.interface(connection, id: id) }
            catch { connection.invalidate(); process.invalidate(); throw error }
            let pid = connection.processIdentifier
            // Only a process running from inside this very app bundle is a module of this kernel.
            let path = Self.path(of: pid)
            guard path.hasPrefix(extensionsPath) else {
                connection.invalidate(); process.invalidate()
                refused = .foreign(path)
                continue
            }
            guard built >= 1, built <= ModuleManifest.currentInterface else {
                connection.invalidate(); process.invalidate()
                throw ModuleError.interface(built)
            }
            guard slot.generation == generation else { connection.invalidate(); process.invalidate(); return }
            slot.identity = identity; slot.process = process; slot.connection = connection; slot.pid = pid
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            source.setEventHandler { [weak self, weak slot] in
                guard let self, let slot, slot.generation == generation, slot.pid == pid else { return }
                self.gone(slot)
            }
            source.resume()
            slot.exit = source
            // The process may have died between the connection and the watch.
            if kill(pid, 0) != 0, errno == ESRCH { throw ModuleError.exited(id) }
            return
        }
        throw refused
    }

    private func release(_ slot: Slot) {
        slot.exit?.cancel(); slot.exit = nil
        slot.connection?.invalidate(); slot.connection = nil
        slot.process?.invalidate(); slot.process = nil
        slot.pid = nil
    }

    /// The process exited, asked or not; the lifecycle knows which.
    private func gone(_ slot: Slot) {
        release(slot)
        // After a planned stop, whoever is waiting wants the next start, which `exited` brings.
        if slot.lifecycle.phase != .stopping { fail(slot, .exited(slot.module.manifest.id)) }
        send(.exited, to: slot)
    }

    private func stop(_ slot: Slot) {
        let id = slot.module.manifest.id, generation = slot.generation
        guard let pid = slot.pid else { send(.exited, to: slot); return }
        for scene in slot.scenes { scene.controller.configuration = nil }
        slot.connection?.invalidate(); slot.connection = nil
        slot.process?.invalidate(); slot.process = nil
        lastStop[id] = "invalidated"
        // Dropping the connection leaves the process running (measured), so it is asked to quit.
        for (delay, signal, name) in [(0.2, SIGTERM, "terminated"), (4.0, SIGKILL, "killed")] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak slot] in
                guard let self, let slot, slot.generation == generation, slot.pid == pid, Self.path(of: pid).hasPrefix(self.extensionsPath) else { return }
                self.lastStop[id] = name
                kill(pid, signal)
            }
        }
    }

    private static func path(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
    }

    private static func interface(_ connection: NSXPCConnection, id: String) async throws -> Int {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Int, Error>) in
            let once = Once()
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in once.run { k.resume(throwing: ModuleError.exited(id)) } } as? ModuleXPC
            guard let proxy else { once.run { k.resume(throwing: ModuleError.exited(id)) }; return }
            proxy.interface { n in once.run { k.resume(returning: n) } }
        }
    }
}

/// The kernel answer until the permission broker exists: every request is refused.
public final class RefusingKernel: NSObject, KernelXPC {
    public func request(_ capability: String, payload: Data, reply: @escaping @Sendable (Data?, String?) -> Void) { reply(nil, "denied: \(capability)") }
}

/// XPC answers either through the reply or through the error handler, sometimes neither twice.
final class Once: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    func run(_ body: () -> Void) {
        lock.lock(); let first = !done; done = true; lock.unlock()
        if first { body() }
    }
}
