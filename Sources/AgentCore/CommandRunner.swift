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
        public var errorOutput = ""
    }

    public static func run(_ executable: String, arguments: [String], directory: String? = nil,
                           environment: [String: String]? = nil, timeout: TimeInterval = 15,
                           outputLimit: Int = 1_048_576, captureError: Bool = true, cancelled: () -> Bool = { false }) -> Result {
        run(executable,arguments:arguments,directory:directory,environment:environment,timeout:timeout,
            outputLimit:outputLimit,captureError:captureError,input:FileHandle.nullDevice,cancelled:cancelled)
    }

    /// Reads stdin from an already-open descriptor at its current offset.
    public static func run(_ executable: String, arguments: [String], directory: String? = nil,
                           environment: [String: String]? = nil, timeout: TimeInterval = 15,
                           outputLimit: Int = 1_048_576, captureError: Bool = true, input: FileHandle, separateError: Bool = false, cancelled: () -> Bool = { false }) -> Result {
        guard timeout.isFinite, timeout > 0 else { return Result(status: -1, output: "invalid timeout", timedOut: false, cancelled: false) }
        if cancelled() { return Result(status: -1, output: "", timedOut: false, cancelled: true) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        process.standardInput = input
        let pipe = Pipe()
        process.standardOutput = pipe
        let errorPipe = captureError && separateError ? Pipe() : nil
        if captureError { process.standardError = errorPipe ?? pipe } else { process.standardError = FileHandle.nullDevice }
        do { try process.run() } catch { return Result(status: -1, output: String(describing: error), timedOut: false, cancelled: false) }
        try? pipe.fileHandleForWriting.close()
        try? errorPipe?.fileHandleForWriting.close()
        let fd = pipe.fileHandleForReading.fileDescriptor
        let errorFD = errorPipe?.fileHandleForReading.fileDescriptor
        defer { try? pipe.fileHandleForReading.close(); try? errorPipe?.fileHandleForReading.close() }
        let descriptors = [fd] + (errorFD.map { [$0] } ?? [])
        guard descriptors.allSatisfy({ descriptor in
            let flags = fcntl(descriptor, F_GETFL)
            return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
        }) else {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            return Result(status: -1, output: "could not configure output pipe", timedOut: false, cancelled: false)
        }
        var output = Data()
        var errorOutput = Data()
        var truncated = false
        let limit = max(0, outputLimit)
        var retainedBytes = 0
        func drainDescriptor(_ descriptor: Int32, into destination: inout Data) {
            var buffer = [UInt8](repeating: 0, count: 16_384)
            for _ in 0..<32 {
                let count = read(descriptor, &buffer, buffer.count)
                guard count > 0 else { return }
                let keep = min(count, max(0, limit - retainedBytes))
                if keep > 0 { destination.append(contentsOf: buffer.prefix(keep)); retainedBytes += keep }
                if keep < count { truncated = true }
            }
        }
        func drain() {
            drainDescriptor(fd, into: &output)
            if let errorFD { drainDescriptor(errorFD, into: &errorOutput) }
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
        result.errorOutput = String(decoding: errorOutput, as: UTF8.self)
        result.truncated = truncated
        return result
    }
}
