import Darwin
import Foundation

/// One message to or from the WebAssembly runner: a 4-byte big-endian length, then JSON.
/// Mirrors `RunnerFrame` in Runtimes/WasmRunner; `protocolVersion` must match on both sides.
public struct WasmRunnerFrame: Codable, Equatable, Sendable {
    public static let protocolVersion = 1
    public static let maximumBytes = 16 * 1024 * 1024

    public var type: String
    public var version: Int?
    public var id: Int?
    public var wasm: Data?
    public var memoryLimit: Int?
    public var fuel: UInt64?
    public var function: String?
    public var input: Data?
    public var status: Int?
    public var output: Data?
    public var capability: String?
    public var payload: Data?
    public var ok: Bool?
    public var data: Data?
    public var outcome: String?
    public var message: String?
    public var exports: [String]?
    public var sandboxed: Bool?
    public var fileAccessDenied: Bool?

    public init(type: String) { self.type = type }

    static func encode(_ frame: WasmRunnerFrame) throws -> Data {
        let body = try JSONEncoder().encode(frame)
        guard body.count <= maximumBytes else { throw WasmHost.Failure.protocolError("frame of \(body.count) bytes is too large") }
        var data = Data([UInt8(truncatingIfNeeded: body.count >> 24), UInt8(truncatingIfNeeded: body.count >> 16),
                         UInt8(truncatingIfNeeded: body.count >> 8), UInt8(truncatingIfNeeded: body.count)])
        data.append(body)
        return data
    }
}

/// The pipe to one runner process. `receive` throws once the process is gone.
public protocol WasmRunnerTransport: AnyObject, Sendable {
    var pid: pid_t? { get }
    func send(_ frame: WasmRunnerFrame) throws
    func receive() async throws -> WasmRunnerFrame
    /// Kills the process; a pending `receive` then throws.
    func terminate()
}

/// How the host gets a fresh runner.
public struct WasmRunnerLauncher: Sendable {
    public let launch: @Sendable () throws -> any WasmRunnerTransport
    public init(launch: @escaping @Sendable () throws -> any WasmRunnerTransport) { self.launch = launch }

    /// `ThermoWasmRunner` as a child process with no arguments and an empty environment.
    public static func process(_ executable: URL) -> WasmRunnerLauncher {
        .init { try ProcessRunnerTransport(executable: executable) }
    }
}

final class ProcessRunnerTransport: WasmRunnerTransport, @unchecked Sendable {
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private let reads = DispatchQueue(label: "dev.thermo.wasm-runner.read")
    private let lock = NSLock()
    private var killed = false

    init(executable: URL) throws {
        process.executableURL = executable
        process.arguments = []
        process.environment = [:]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    var pid: pid_t? { process.isRunning ? process.processIdentifier : nil }

    func send(_ frame: WasmRunnerFrame) throws {
        let data = try WasmRunnerFrame.encode(frame)
        let fd = input.fileHandleForWriting.fileDescriptor
        var offset = 0
        while offset < data.count {
            let written = data[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written < 0 { if errno == EINTR { continue }; throw WasmHost.Failure.crashed }
            offset += written
        }
    }

    func receive() async throws -> WasmRunnerFrame {
        let fd = output.fileHandleForReading.fileDescriptor
        return try await withCheckedThrowingContinuation { continuation in
            reads.async {
                do {
                    let header = try Self.read(fd, 4)
                    let length = header.reduce(0) { ($0 << 8) | Int($1) }
                    guard length <= WasmRunnerFrame.maximumBytes else { throw WasmHost.Failure.protocolError("frame of \(length) bytes is too large") }
                    let body = try Self.read(fd, length)
                    continuation.resume(returning: try JSONDecoder().decode(WasmRunnerFrame.self, from: Data(body)))
                } catch let failure as WasmHost.Failure {
                    continuation.resume(throwing: failure)
                } catch {
                    continuation.resume(throwing: WasmHost.Failure.protocolError("\(error)"))
                }
            }
        }
    }

    private static func read(_ fd: Int32, _ count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count), offset = 0
        while offset < count {
            let got = buffer[offset...].withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if got < 0 { if errno == EINTR { continue }; throw WasmHost.Failure.crashed }
            if got == 0 { throw WasmHost.Failure.crashed }
            offset += got
        }
        return buffer
    }

    func terminate() {
        lock.lock(); defer { lock.unlock() }
        guard !killed else { return }
        killed = true
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        try? input.fileHandleForWriting.close()
    }

    deinit { terminate() }
}
