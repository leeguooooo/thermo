import Darwin
import Foundation
import ModuleHost
import ModuleKit

/// Runs one third-party WebAssembly module for the kernel (#46).
///
/// The module executes in its own `ThermoWasmRunner` process, which loads it and then locks itself
/// down to pure computation: no files, no network. Its only way out is a capability request over the
/// pipe, which this host hands to the module's `CapabilityBroker` — the same manifest check, kernel
/// rules, confirmation and access log every module gets. An undeclared capability is refused there.
///
/// Limits: the runner refuses memory growth past `memoryBytes` and stops a call after `fuel`
/// operators; this host kills the process when a call runs longer than `callTimeout` (time spent
/// waiting for the kernel or the person does not count) or its footprint passes `footprintBytes`.
/// A crash or kill is an error for that call only. `suspendAfter` failures in a row switch the module
/// off until `resume()`.
public actor WasmHost {
    public struct Limits: Sendable, Equatable {
        public var memoryBytes: Int
        public var footprintBytes: UInt64
        public var callTimeout: TimeInterval
        public var loadTimeout: TimeInterval
        public var fuel: UInt64?
        public var suspendAfter: Int
        public init(memoryBytes: Int = 64 << 20, footprintBytes: UInt64 = 256 << 20, callTimeout: TimeInterval = 5,
                    loadTimeout: TimeInterval = 5, fuel: UInt64? = 2_000_000_000, suspendAfter: Int = 3) {
            self.memoryBytes = memoryBytes; self.footprintBytes = footprintBytes; self.callTimeout = callTimeout
            self.loadTimeout = loadTimeout; self.fuel = fuel; self.suspendAfter = max(1, suspendAfter)
        }
    }

    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        /// WebAssembly modules need macOS 15 or later.
        case unsupported
        /// Switched off after failing again and again.
        case suspended
        case badModule(String)
        case notSandboxed
        case timedOut
        case memoryExceeded
        case outOfFuel
        case trapped(String)
        case crashed
        case protocolError(String)

        public var description: String {
            switch self {
            case .unsupported: return "WebAssembly modules need macOS 15 or later"
            case .suspended: return "switched off after failing repeatedly"
            case .badModule(let m): return "the module could not be loaded: \(m)"
            case .notSandboxed: return "the runner could not prove it is sandboxed"
            case .timedOut: return "the call took too long and was stopped"
            case .memoryExceeded: return "the module used too much memory and was stopped"
            case .outOfFuel: return "the call used up its execution budget"
            case .trapped(let m): return "the module failed: \(m)"
            case .crashed: return "the module process ended unexpectedly"
            case .protocolError(let m): return "the runner answered something unexpected: \(m)"
            }
        }
    }

    public struct Result: Sendable, Equatable {
        public var status: Int
        public var output: Data
        public init(status: Int, output: Data) { self.status = status; self.output = output }
    }

    public static var isSupported: Bool {
        if #available(macOS 15, *) { return true } else { return false }
    }

    public nonisolated let manifest: ModuleManifest
    private let wasm: Data
    private let broker: CapabilityBroker
    public nonisolated let limits: Limits
    private let launcher: WasmRunnerLauncher
    private let footprint: @Sendable (pid_t) -> UInt64?
    private let supported: Bool

    private var transport: (any WasmRunnerTransport)?
    public private(set) var failures = 0
    public private(set) var suspended = false
    public private(set) var exports: [String] = []
    public private(set) var launches = 0
    private var nextID = 0
    private var gate: Task<Void, Never>?

    public init(manifest: ModuleManifest, wasm: Data, broker: CapabilityBroker, limits: Limits = Limits(),
                launcher: WasmRunnerLauncher, supported: Bool = WasmHost.isSupported,
                footprint: @escaping @Sendable (pid_t) -> UInt64? = { ModuleUsage.read($0)?.footprintBytes }) {
        self.manifest = manifest; self.wasm = wasm; self.broker = broker; self.limits = limits
        self.launcher = launcher; self.supported = supported; self.footprint = footprint
    }

    /// Runs one command function. Calls are served one at a time, in order.
    public func call(_ function: String, input: Data = Data()) async throws -> Result {
        let previous = gate
        let work = Task { () async throws -> Result in
            _ = await previous?.result
            return try await self.perform(function, input)
        }
        gate = Task { _ = await work.result }
        return try await work.value
    }

    /// The person switched the module on again.
    public func resume() { suspended = false; failures = 0 }

    public func stop() {
        if let transport { try? transport.send(WasmRunnerFrame(type: "exit")); transport.terminate() }
        transport = nil
    }

    // MARK: -

    private func perform(_ function: String, _ input: Data) async throws -> Result {
        guard supported else { throw Failure.unsupported }
        guard !suspended else { throw Failure.suspended }
        do {
            let runner = try await ready()
            nextID += 1
            var call = WasmRunnerFrame(type: "call")
            call.id = nextID; call.function = function; call.input = input; call.fuel = limits.fuel
            let watch = Watchdog(transport: runner, timeout: limits.callTimeout, footprintLimit: limits.footprintBytes, footprint: footprint)
            defer { watch.stop() }
            do {
                try runner.send(call)
                while true {
                    let frame = try await runner.receive()
                    switch frame.type {
                    case "request":
                        watch.pause()
                        let answer = await broker.request(frame.capability ?? "", payload: frame.payload ?? Data())
                        watch.resume()
                        var reply = WasmRunnerFrame(type: "answer")
                        switch answer {
                        case .success(let data): reply.ok = true; reply.data = data
                        case .failure(let error): reply.ok = false; reply.outcome = error.outcome.rawValue; reply.message = error.message
                        }
                        try runner.send(reply)
                    case "result":
                        guard frame.id == call.id else { throw Failure.protocolError("result for another call") }
                        failures = 0
                        return Result(status: frame.status ?? 0, output: frame.output ?? Data())
                    case "trap":
                        throw frame.outcome == "outOfFuel" ? Failure.outOfFuel : Failure.trapped(frame.message ?? "trap")
                    default:
                        throw Failure.protocolError("unexpected \(frame.type)")
                    }
                }
            } catch let failure as Failure {
                // The watchdog's reason wins: the read failed because it killed the runner.
                throw watch.reason ?? failure
            } catch {
                throw watch.reason ?? Failure.protocolError("\(error)")
            }
        } catch let failure as Failure {
            throw record(failure)
        }
    }

    /// Counts a failure; anything but a trap or an exhausted budget means the process is gone or untrusted.
    private func record(_ failure: Failure) -> Failure {
        switch failure {
        case .trapped, .outOfFuel: break
        default: transport?.terminate(); transport = nil
        }
        failures += 1
        if failures >= limits.suspendAfter {
            suspended = true
            stop()
            NSLog("thermo wasm module suspended after %d failures in a row: %@", failures, manifest.id)
        }
        return failure
    }

    private func ready() async throws -> any WasmRunnerTransport {
        if let transport { return transport }
        let runner: any WasmRunnerTransport
        do { runner = try launcher.launch() } catch { throw Failure.protocolError("could not start the runner: \(error)") }
        launches += 1
        transport = runner
        var load = WasmRunnerFrame(type: "load")
        load.version = WasmRunnerFrame.protocolVersion; load.wasm = wasm; load.memoryLimit = limits.memoryBytes; load.fuel = limits.fuel
        let watch = Watchdog(transport: runner, timeout: limits.loadTimeout, footprintLimit: limits.footprintBytes, footprint: footprint)
        defer { watch.stop() }
        let answer: WasmRunnerFrame
        do {
            try runner.send(load)
            answer = try await runner.receive()
        } catch {
            throw watch.reason ?? (error as? Failure) ?? Failure.crashed
        }
        switch answer.type {
        case "loaded":
            // Never run a module in a runner that did not show its file access is gone.
            guard answer.sandboxed == true, answer.fileAccessDenied == true else { throw Failure.notSandboxed }
            guard answer.version == WasmRunnerFrame.protocolVersion else { throw Failure.protocolError("runner protocol \(answer.version ?? 0)") }
            exports = answer.exports ?? []
            return runner
        case "error":
            throw Failure.badModule(answer.message ?? "unknown error")
        default:
            throw Failure.protocolError("unexpected \(answer.type)")
        }
    }
}

/// Kills the runner when a call runs too long or grows too big. Time is only counted while the
/// module itself is running, not while the kernel or the person is answering one of its requests.
final class Watchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var spent: TimeInterval = 0
    private var since: TimeInterval? = ProcessInfo.processInfo.systemUptime
    private var stopped = false
    private var _reason: WasmHost.Failure?
    private var task: Task<Void, Never>?

    var reason: WasmHost.Failure? { lock.lock(); defer { lock.unlock() }; return _reason }

    init(transport: any WasmRunnerTransport, timeout: TimeInterval, footprintLimit: UInt64,
         footprint: @escaping @Sendable (pid_t) -> UInt64?) {
        task = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000)
                guard let self else { return }
                let verdict: WasmHost.Failure? = self.lock.withLock {
                    guard !self.stopped, self._reason == nil else { return nil }
                    let now = ProcessInfo.processInfo.systemUptime
                    let used = self.spent + (self.since.map { now - $0 } ?? 0)
                    if used > timeout { return .timedOut }
                    return nil
                }
                var over = verdict
                if over == nil, let pid = transport.pid, let bytes = footprint(pid), bytes > footprintLimit { over = .memoryExceeded }
                if let over {
                    let first: Bool = self.lock.withLock {
                        guard !self.stopped, self._reason == nil else { return false }
                        self._reason = over; return true
                    }
                    if first { transport.terminate() }
                    return
                }
            }
        }
    }

    func pause() {
        lock.withLock { if let since { spent += ProcessInfo.processInfo.systemUptime - since }; since = nil }
    }
    func resume() { lock.withLock { since = ProcessInfo.processInfo.systemUptime } }
    func stop() { lock.withLock { stopped = true }; task?.cancel() }
}
