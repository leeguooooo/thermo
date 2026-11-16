import Foundation
@_spi(Fuzzing) import WasmKit

/// Where a module's capability requests go. In the runner process that is the kernel, over the pipe.
public protocol RunnerKernel: AnyObject {
    /// `ok` false carries the refusal's outcome (`denied`, `declined`, `failed`) in `outcome`.
    func request(capability: String, payload: Data) throws -> (ok: Bool, data: Data, outcome: String?)
}

public enum RunnerError: Error, Equatable, CustomStringConvertible {
    case badModule(String)
    case missingExport(String)
    case noSuchFunction(String)
    case outOfFuel
    case trap(String)
    case guestMemory(String)

    public var description: String {
        switch self {
        case .badModule(let m): return "invalid module: \(m)"
        case .missingExport(let m): return "module does not export \(m)"
        case .noSuchFunction(let m): return "no command function \(m)"
        case .outOfFuel: return "execution budget used up"
        case .trap(let m): return "trap: \(m)"
        case .guestMemory(let m): return "guest memory: \(m)"
        }
    }
}

/// Refuses memory growth past a fixed number of bytes; WasmKit turns a refusal into `memory.grow` returning -1.
final class MemoryCap: ResourceLimiter, @unchecked Sendable {
    let bytes: Int
    init(bytes: Int) { self.bytes = bytes }
    func limitMemoryGrowth(to desired: Int) throws -> Bool { desired <= bytes }
    func limitTableGrowth(to desired: Int) throws -> Bool { desired <= 100_000 }
}

/// One instantiated module and the ABI Thermo gives it.
///
/// The guest exports `memory`, `thermo_alloc(len) -> ptr`, and command functions `(ptr, len) -> status`
/// that read their input from the given bytes. It imports from `thermo`:
/// - `request(capPtr, capLen, payloadPtr, payloadLen) -> i32`: asks the kernel; returns the answer's length,
///   or -1 denied, -2 declined, -3 failed, -4 anything else. The answer is fetched with `answer`.
/// - `answer(ptr, len) -> i32`: copies up to `len` bytes of the last answer, returns how many.
/// - `output(ptr, len)`: sets the command's output.
/// Nothing else is importable: no WASI, no clock, no files. Everything outside goes through `request`.
public final class ModuleRunner {
    public static let maximumOutput = 4 * 1024 * 1024
    public static let maximumRequest = 1024 * 1024

    private let store: Store
    private let instance: Instance
    private weak var kernel: RunnerKernel?
    private var lastAnswer = Data()
    private var output = Data()
    public let exports: [String]

    public init(wasm: [UInt8], memoryLimit: Int, kernel: RunnerKernel) throws {
        let module: Module
        do { module = try parseWasm(bytes: wasm) } catch { throw RunnerError.badModule("\(error)") }
        let engine = Engine(configuration: EngineConfiguration(fuelMetering: true))
        let store = Store(engine: engine)
        store.resourceLimiter = MemoryCap(bytes: memoryLimit)
        var imports = Imports()
        // Box so the host functions can reach `self` once it exists.
        let box = Box()
        imports.define(module: "thermo", name: "request",
                       Function(store: store, parameters: [.i32, .i32, .i32, .i32], results: [.i32]) { caller, args in
            guard let runner = box.runner, let memory = caller.instance?.exports[memory: "memory"] else { return [.i32(UInt32(bitPattern: -4))] }
            let capability = try Self.bytes(memory, args[0], args[1], limit: 4096)
            let payload = try Self.bytes(memory, args[2], args[3], limit: Self.maximumRequest)
            return [.i32(UInt32(bitPattern: runner.forward(String(decoding: capability, as: UTF8.self), Data(payload))))]
        })
        imports.define(module: "thermo", name: "answer",
                       Function(store: store, parameters: [.i32, .i32], results: [.i32]) { caller, args in
            guard let runner = box.runner, let memory = caller.instance?.exports[memory: "memory"] else { return [.i32(0)] }
            let count = min(Int(args[1].i32), runner.lastAnswer.count)
            try Self.write(memory, at: args[0].i32, Array(runner.lastAnswer.prefix(count)))
            return [.i32(UInt32(count))]
        })
        imports.define(module: "thermo", name: "output",
                       Function(store: store, parameters: [.i32, .i32]) { caller, args in
            guard let runner = box.runner, let memory = caller.instance?.exports[memory: "memory"] else { return [] }
            runner.output = Data(try Self.bytes(memory, args[0], args[1], limit: Self.maximumOutput))
            return []
        })
        let instance: Instance
        do { instance = try module.instantiate(store: store, imports: imports) }
        catch { throw RunnerError.badModule("\(error)") }
        self.store = store; self.instance = instance; self.kernel = kernel
        guard instance.exports[memory: "memory"] != nil else { throw RunnerError.missingExport("memory") }
        guard instance.exports[function: "thermo_alloc"] != nil else { throw RunnerError.missingExport("thermo_alloc") }
        exports = instance.exports.compactMap { name, value in
            if case .function = value, name != "thermo_alloc" { return name } else { return nil }
        }.sorted()
        box.runner = self
    }

    private final class Box { weak var runner: ModuleRunner? }

    /// Runs a command function with `input`; `fuel` bounds how many operators it may execute.
    public func call(_ name: String, input: Data, fuel: UInt64?) throws -> (status: Int, output: Data) {
        guard let function = instance.exports[function: name], name != "thermo_alloc" else { throw RunnerError.noSuchFunction(name) }
        guard let alloc = instance.exports[function: "thermo_alloc"], let memory = instance.exports[memory: "memory"] else {
            throw RunnerError.missingExport("thermo_alloc")
        }
        output = Data(); lastAnswer = Data()
        store.fuel = fuel.map { Fuel(remaining: $0) }
        do {
            let pointer = try alloc([.i32(UInt32(input.count))])
            guard let base = pointer.first?.i32 else { throw RunnerError.guestMemory("thermo_alloc returned nothing") }
            try Self.write(memory, at: base, Array(input))
            let result = try function([.i32(base), .i32(UInt32(input.count))])
            let status = result.first.map { Int(Int32(bitPattern: $0.i32)) } ?? 0
            return (status, output)
        } catch let error as RunnerError {
            throw error
        } catch let trap as Trap {
            if trap.description.contains("out of fuel") { throw RunnerError.outOfFuel }
            throw RunnerError.trap(trap.description.components(separatedBy: "\n").first ?? "\(trap)")
        } catch {
            throw RunnerError.trap("\(error)")
        }
    }

    private func forward(_ capability: String, _ payload: Data) -> Int32 {
        lastAnswer = Data()
        guard let kernel, let answer = try? kernel.request(capability: capability, payload: payload) else { return -4 }
        if answer.ok { lastAnswer = answer.data; return Int32(clamping: answer.data.count) }
        switch answer.outcome {
        case "denied": return -1
        case "declined": return -2
        case "failed": return -3
        default: return -4
        }
    }

    static func bytes(_ memory: Memory, _ pointer: Value, _ length: Value, limit: Int) throws -> [UInt8] {
        let start = Int(pointer.i32), count = Int(length.i32)
        guard count <= limit else { throw RunnerError.guestMemory("\(count) bytes is over the \(limit)-byte limit") }
        guard start + count <= memory.byteCount else { throw RunnerError.guestMemory("out of bounds") }
        return memory.withUnsafeBufferPointer(offset: UInt(start), count: count) { Array($0) }
    }

    static func write(_ memory: Memory, at pointer: UInt32, _ bytes: [UInt8]) throws {
        let start = Int(pointer)
        guard start + bytes.count <= memory.byteCount else { throw RunnerError.guestMemory("out of bounds") }
        guard !bytes.isEmpty else { return }
        memory.withUnsafeMutableBufferPointer(offset: UInt(start), count: bytes.count) { target in
            bytes.withUnsafeBytes { target.copyMemory(from: $0) }
        }
    }
}
