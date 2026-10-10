import Darwin
import Foundation

/// Runs only its own child process; output is drained even when the retained text reaches its cap.
public enum CommandRunner {
    public struct Result: Sendable {
        public var status: Int32
        public var output: String
        public var timedOut: Bool
        public var cancelled: Bool
        public var truncated = false
    }

    public static func run(_ executable: String, arguments: [String], directory: String? = nil,
                           environment: [String: String]? = nil, timeout: TimeInterval = 15,
                           outputLimit: Int = 1_048_576, captureError: Bool = true, cancelled: () -> Bool = { false }) -> Result {
        guard timeout.isFinite, timeout > 0 else { return Result(status: -1, output: "invalid timeout", timedOut: false, cancelled: false) }
        if cancelled() { return Result(status: -1, output: "", timedOut: false, cancelled: true) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        if captureError { process.standardError = pipe } else { process.standardError = FileHandle.nullDevice }
        do { try process.run() } catch { return Result(status: -1, output: String(describing: error), timedOut: false, cancelled: false) }
        try? pipe.fileHandleForWriting.close()
        let fd = pipe.fileHandleForReading.fileDescriptor
        defer { try? pipe.fileHandleForReading.close() }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            return Result(status: -1, output: "could not configure output pipe", timedOut: false, cancelled: false)
        }
        var output = Data()
        var truncated = false
        let limit = max(0, outputLimit)
        func drain() {
            var buffer = [UInt8](repeating: 0, count: 16_384)
            for _ in 0..<32 {
                let count = read(fd, &buffer, buffer.count)
                guard count > 0 else { return }
                let keep = min(count, max(0, limit - output.count))
                if keep > 0 { output.append(contentsOf: buffer.prefix(keep)) }
                if keep < count { truncated = true }
            }
        }
        let started = DispatchTime.now().uptimeNanoseconds
        var timeoutReached = false
        var cancellationReached = false
        while process.isRunning {
            drain()
            cancellationReached = cancelled()
            timeoutReached = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9 >= timeout
            if cancellationReached || timeoutReached {
                process.terminate()
                let stoppedAt = DispatchTime.now().uptimeNanoseconds
                while process.isRunning && Double(DispatchTime.now().uptimeNanoseconds - stoppedAt) / 1e9 < 0.3 { drain(); usleep(10_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            usleep(10_000)
        }
        process.waitUntilExit()
        drain()
        var result = Result(status: process.terminationStatus, output: String(decoding: output, as: UTF8.self),
                            timedOut: timeoutReached, cancelled: cancellationReached)
        result.truncated = truncated
        return result
    }
}
