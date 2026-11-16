import Foundation

/// One message between the kernel and the runner: a 4-byte big-endian length, then JSON.
/// Mirrored by `WasmRunnerFrame` in the app's WasmHost target; the two must stay in step
/// (`RunnerFrame.protocolVersion` guards it).
public struct RunnerFrame: Codable, Equatable, Sendable {
    public static let protocolVersion = 1
    public static let maximumBytes = 16 * 1024 * 1024

    /// kernel → runner: load, call, answer, exit. runner → kernel: loaded, request, result, trap, error.
    public var type: String
    public var version: Int?
    public var id: Int?
    // load
    public var wasm: Data?
    public var memoryLimit: Int?
    public var fuel: UInt64?
    // call / result
    public var function: String?
    public var input: Data?
    public var status: Int?
    public var output: Data?
    // request / answer
    public var capability: String?
    public var payload: Data?
    public var ok: Bool?
    public var data: Data?
    public var outcome: String?
    // loaded / trap / error
    public var message: String?
    public var exports: [String]?
    public var sandboxed: Bool?
    public var fileAccessDenied: Bool?

    public init(type: String) { self.type = type }
}

public enum FrameError: Error, Equatable {
    case closed, tooLarge(Int), malformed(String)
}

/// Blocking frame I/O on plain file descriptors (the runner's stdin and stdout).
public struct FrameIO {
    public let input: Int32
    public let output: Int32
    public init(input: Int32, output: Int32) { self.input = input; self.output = output }

    public func read() throws -> RunnerFrame {
        let header = try readExactly(4)
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        guard length <= RunnerFrame.maximumBytes else { throw FrameError.tooLarge(length) }
        let body = try readExactly(length)
        do { return try JSONDecoder().decode(RunnerFrame.self, from: Data(body)) }
        catch { throw FrameError.malformed("\(error)") }
    }

    public func write(_ frame: RunnerFrame) throws {
        let body = try JSONEncoder().encode(frame)
        guard body.count <= RunnerFrame.maximumBytes else { throw FrameError.tooLarge(body.count) }
        var bytes = [UInt8(truncatingIfNeeded: body.count >> 24), UInt8(truncatingIfNeeded: body.count >> 16),
                     UInt8(truncatingIfNeeded: body.count >> 8), UInt8(truncatingIfNeeded: body.count)]
        bytes.append(contentsOf: body)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(output, $0.baseAddress, $0.count) }
            if written < 0 { if errno == EINTR { continue }; throw FrameError.closed }
            offset += written
        }
    }

    private func readExactly(_ count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count), offset = 0
        while offset < count {
            let got = buffer[offset...].withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress, $0.count) }
            if got < 0 { if errno == EINTR { continue }; throw FrameError.closed }
            if got == 0 { throw FrameError.closed }
            offset += got
        }
        return buffer
    }
}
