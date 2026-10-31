import Foundation

public struct ToolResult: Sendable, Equatable {
    public var exitCode: Int32
    public var timedOut: Bool
    public var stderrTail: String

    public init(exitCode: Int32, timedOut: Bool = false, stderrTail: String = "") {
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.stderrTail = stderrTail
    }
}

public protocol ToolRunner: Sendable {
    func run(
        executable: URL, arguments: [String], timeout: TimeInterval, onStdoutLine: @escaping @Sendable (String) -> Void
    ) async throws -> ToolResult
}

public struct ProcessToolRunner: ToolRunner {
    public init() {}

    public func run(
        executable: URL, arguments: [String], timeout: TimeInterval, onStdoutLine: @escaping @Sendable (String) -> Void
    ) async throws -> ToolResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        let output = ProcessOutput()
        let exited = AsyncStream<Void> { continuation in
            process.terminationHandler = { _ in continuation.finish() }
        }
        try process.run()

        // Both pipes drain from the start, so a chatty tool cannot block on a full pipe.
        let readers = [
            Task.detached { try? await Self.forEachLine(stdout, onStdoutLine) },
            Task.detached { try? await Self.forEachLine(stderr) { output.appendStderr($0) } },
        ]
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak process] in
            guard let process, process.isRunning else { return }
            output.markTimedOut()
            process.terminate()
        }
        await withTaskCancellationHandler {
            for await _ in exited {}
        } onCancel: {
            process.terminate()
        }
        // Lines still in the pipe when the tool exits matter: ffprobe prints and quits.
        for reader in readers { await reader.value }
        try Task.checkCancellation()
        return ToolResult(exitCode: process.terminationStatus, timedOut: output.timedOut, stderrTail: output.tail)
    }

    private static func forEachLine(_ pipe: Pipe, _ body: @Sendable (String) -> Void) async throws {
        for try await line in pipe.fileHandleForReading.bytes.lines { body(line) }
    }
}

private final class ProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    private var stderr = ""

    func markTimedOut() { lock.withLock { flag = true } }
    var timedOut: Bool { lock.withLock { flag } }
    var tail: String { lock.withLock { stderr } }

    func appendStderr(_ line: String) {
        lock.withLock { stderr = String((stderr + line + "\n").suffix(600)) }
    }
}
