import Foundation
import XCTest
@testable import MediaToolsKit

func makeRoot() throws -> MediaToolsRoot {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mtk-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return MediaToolsRoot(url: url)
}

/// Enough of a Mach-O for the launch gate; nothing in the tests executes it.
func writeFakeBinary(_ url: URL, mode: Int = 0o755) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([0xCF, 0xFA, 0xED, 0xFE, 1, 2, 3]).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
}

func makeZip(containing file: URL, at entry: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zip-\(UUID().uuidString)", isDirectory: true)
    let inner = dir.appendingPathComponent(entry)
    try FileManager.default.createDirectory(at: inner.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: file, to: inner)
    let zip = dir.appendingPathExtension("zip")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-c", "-k", dir.path, zip.path]
    try process.run()
    process.waitUntilExit()
    return zip
}

final class FakeTransport: MediaHTTPTransport, @unchecked Sendable {
    struct Reply {
        var status = 200
        var body = Data()
        var finalURL: URL?
    }

    private let lock = NSLock()
    private var routes: [String: [Reply]] = [:]
    private(set) var sent: [MediaRequest] = []

    /// Key is `METHOD url`, or `METHOD path` for loopback calls. The last reply repeats.
    func on(_ key: String, _ reply: Reply) {
        lock.withLock { routes[key, default: []].append(reply) }
    }

    func on(_ key: String, json: Any) {
        on(key, Reply(body: try! JSONSerialization.data(withJSONObject: json)))
    }

    func requests(_ method: String, _ path: String) -> [MediaRequest] {
        lock.withLock { sent.filter { $0.method == method && $0.url.path == path } }
    }

    func send(_ request: MediaRequest) async throws -> MediaResponse {
        let reply = lock.withLock { () -> Reply? in
            sent.append(request)
            for key in ["\(request.method) \(request.url.absoluteString)", "\(request.method) \(request.url.path)"] {
                guard var queue = routes[key], let first = queue.first else { continue }
                if queue.count > 1 { queue.removeFirst(); routes[key] = queue }
                return first
            }
            return nil
        }
        guard let reply else { return MediaResponse(statusCode: 404, finalURL: request.url, body: Self.stream(Data())) }
        return MediaResponse(statusCode: reply.status, finalURL: reply.finalURL ?? request.url, body: Self.stream(reply.body))
    }

    private static func stream(_ data: Data) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            if !data.isEmpty { continuation.yield(data) }
            continuation.finish()
        }
    }
}

final class FakeRunner: ToolRunner, @unchecked Sendable {
    typealias Handler = @Sendable (URL, [String], (String) -> Void) -> ToolResult
    private let lock = NSLock()
    private(set) var calls: [(URL, [String])] = []
    var handler: Handler = { _, _, _ in ToolResult(exitCode: 0) }

    func run(executable: URL, arguments: [String], timeout: TimeInterval, onStdoutLine: @escaping @Sendable (String) -> Void) async throws -> ToolResult {
        lock.withLock { calls.append((executable, arguments)) }
        return handler(executable, arguments, onStdoutLine)
    }
}

final class FakeProcess: GopeedProcess, @unchecked Sendable {
    let pid: Int32 = 4242
    private let lock = NSLock()
    private var running = true
    private var code: Int32?
    private(set) var terminated = 0
    private(set) var killed = 0
    var ignoresTerminate = false

    var isRunning: Bool { lock.withLock { running } }
    var exitCode: Int32? { lock.withLock { code } }

    func exit(_ status: Int32) { lock.withLock { running = false; code = status } }
    func terminate() {
        terminated += 1
        if !ignoresTerminate { exit(0) }
    }
    func forceKill() {
        killed += 1
        exit(9)
    }
}

final class FakeLauncher: GopeedLauncher, @unchecked Sendable {
    let process = FakeProcess()
    private(set) var launches: [(URL, [String])] = []
    var paths: [Int32: String] = [:]
    private(set) var killed: [Int32] = []

    func launch(executable: URL, arguments: [String], workingDirectory: URL) throws -> GopeedProcess {
        launches.append((executable, arguments))
        return process
    }
    func executablePath(pid: Int32) -> String? { paths[pid] }
    func forceKill(pid: Int32) { killed.append(pid) }
    func freePort() throws -> Int { 53111 }
}
