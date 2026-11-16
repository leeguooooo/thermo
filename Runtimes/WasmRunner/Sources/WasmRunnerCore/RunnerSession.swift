import Foundation

@_silgen_name("sandbox_init")
private func c_sandbox_init(_ profile: UnsafePointer<CChar>, _ flags: UInt64,
                            _ errorbuf: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
@_silgen_name("sandbox_free_error")
private func c_sandbox_free_error(_ errorbuf: UnsafeMutablePointer<CChar>?)

/// Locks this process down to pure computation: no files, no network, no other processes.
/// Pipes opened before the call keep working. Returns nil on success, else the reason.
public func enterPureComputationSandbox() -> String? {
    var error: UnsafeMutablePointer<CChar>?
    // kSBXProfilePureComputation with SANDBOX_NAMED (1).
    let result = "pure-computation".withCString { c_sandbox_init($0, 1, &error) }
    guard result != 0 else { return nil }
    let message = error.map { String(cString: $0) } ?? "sandbox_init failed"
    c_sandbox_free_error(error)
    return message
}

/// The runner process's whole life: read the module, lock down, then answer calls until the pipe closes.
public final class RunnerSession: RunnerKernel {
    let io: FrameIO
    public init(io: FrameIO) { self.io = io }

    public func request(capability: String, payload: Data) throws -> (ok: Bool, data: Data, outcome: String?) {
        var frame = RunnerFrame(type: "request")
        frame.capability = capability; frame.payload = payload
        try io.write(frame)
        let answer = try io.read()
        guard answer.type == "answer" else { throw FrameError.malformed("expected an answer, got \(answer.type)") }
        return (answer.ok == true, answer.data ?? Data(), answer.outcome)
    }

    /// Exit code: 0 when the kernel closed the pipe, 65 for a bad first frame, 70 when locking down failed.
    public func run() -> Int32 {
        guard let load = try? io.read(), load.type == "load", let wasm = load.wasm else { return 65 }
        guard load.version == RunnerFrame.protocolVersion else {
            var error = RunnerFrame(type: "error"); error.message = "protocol version \(load.version ?? 0) is not \(RunnerFrame.protocolVersion)"
            try? io.write(error); return 65
        }
        // Before anything from the module runs.
        if let why = enterPureComputationSandbox() {
            var error = RunnerFrame(type: "error"); error.message = "sandbox: \(why)"
            try? io.write(error); return 70
        }
        // Evidence for the kernel that the lock-down took: a plain file read must fail now.
        let probe = open("/etc/hosts", O_RDONLY)
        if probe >= 0 { close(probe) }
        let runner: ModuleRunner
        do { runner = try ModuleRunner(wasm: Array(wasm), memoryLimit: load.memoryLimit ?? 64 << 20, kernel: self) }
        catch {
            var frame = RunnerFrame(type: "error"); frame.message = "\(error)"
            try? io.write(frame); return 65
        }
        var loaded = RunnerFrame(type: "loaded")
        loaded.version = RunnerFrame.protocolVersion; loaded.exports = runner.exports
        loaded.sandboxed = true; loaded.fileAccessDenied = probe < 0
        guard (try? io.write(loaded)) != nil else { return 0 }
        while true {
            guard let frame = try? io.read() else { return 0 }
            switch frame.type {
            case "exit": return 0
            case "call":
                var reply: RunnerFrame
                do {
                    let result = try runner.call(frame.function ?? "", input: frame.input ?? Data(), fuel: frame.fuel ?? load.fuel)
                    reply = RunnerFrame(type: "result"); reply.status = result.status; reply.output = result.output
                } catch RunnerError.outOfFuel {
                    reply = RunnerFrame(type: "trap"); reply.outcome = "outOfFuel"; reply.message = RunnerError.outOfFuel.description
                } catch {
                    reply = RunnerFrame(type: "trap"); reply.outcome = "trap"; reply.message = "\(error)"
                }
                reply.id = frame.id
                guard (try? io.write(reply)) != nil else { return 0 }
            default:
                return 65
            }
        }
    }
}
