import Foundation
import Network
import XCTest
@testable import DownloadKit

/// A real HTTP/1.1 server on loopback. Each request gets one connection-close response.
private final class LocalServer: @unchecked Sendable {
    struct Request { var path: String; var headers: [String: String] }
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "local-server")
    private let lock = NSLock()
    private var seen: [Request] = []
    private var broken = 0
    var brokenSends: Int { lock.withLock { broken } }
    private let handler: @Sendable (Request) -> Reply
    private(set) var port: UInt16 = 0
    var requests: [Request] { lock.withLock { seen } }
    var baseURL: String { "http://127.0.0.1:\(port)" }

    init(handler: @escaping @Sendable (Request) -> Reply) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        self.handler = handler
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.read(connection, Data())
        }
        let ready: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            let listener = self.listener
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error): once.run { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        port = ready
    }

    deinit { listener.cancel() }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func run(_ body: () -> Void) {
            let first = lock.withLock { () -> Bool in
                defer { done = true }
                return !done
            }
            if first { body() }
        }
    }

    private func read(_ connection: NWConnection, _ received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, end, error in
            guard let self else { return }
            var all = received
            if let data { all.append(data) }
            if let split = all.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(connection, head: String(decoding: all[..<split.lowerBound], as: UTF8.self))
            } else if !end, error == nil {
                self.read(connection, all)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(_ connection: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let path = lines[0].split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let request = Request(path: path, headers: headers)
        lock.withLock { seen.append(request) }
        let reply = handler(request)
        var text = "HTTP/1.1 \(reply.status) X\r\nConnection: close\r\nContent-Length: \(reply.body.count)\r\n"
        for (name, value) in reply.headers { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        send(connection, Data(text.utf8) + reply.body)
    }

    private func send(_ connection: NWConnection, _ data: Data) {
        let piece = data.prefix(1 << 18)
        let rest = data.dropFirst(piece.count)
        connection.send(content: piece, completion: .contentProcessed { [weak self] error in
            guard let self else { return connection.cancel() }
            if error != nil {
                self.lock.withLock { self.broken += 1 }
                connection.cancel()
            } else if rest.isEmpty {
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            } else {
                self.send(connection, Data(rest))
            }
        })
    }

    /// Serves `content`, honoring `Range` when asked to.
    static func ranged(_ content: Data, ranges: Bool = true, extra: [String: String] = ["ETag": "\"v1\""]) -> @Sendable (Request) -> Reply {
        { request in
            guard ranges, let header = request.headers["range"], header.hasPrefix("bytes=") else {
                return Reply(headers: extra, body: content)
            }
            let bounds = header.dropFirst(6).split(separator: "-").compactMap { Int($0) }
            let upper = min(bounds[1], content.count - 1)
            var headers = extra
            headers["Content-Range"] = "bytes \(bounds[0])-\(upper)/\(content.count)"
            return Reply(status: 206, headers: headers, body: content.subdata(in: bounds[0]..<(upper + 1)))
        }
    }
}

final class URLSessionTransportTests: XCTestCase {
    private var directory: URL!
    private func payload(_ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) }) }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Transport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func engine(concurrency: Int = 4, minimum: Int64 = 1 << 16, transport: URLSessionTransport = URLSessionTransport()) -> DownloadEngine {
        DownloadEngine(
            configuration: DownloadConfiguration(concurrency: concurrency, minimumSegmentSize: minimum, maxRetries: 1),
            transport: transport, store: DownloadStore(root: directory.appendingPathComponent("state"))
        )
    }

    private func read(_ response: FetchResponse) async throws -> Data {
        var data = Data()
        for try await chunk in response.body { data.append(chunk) }
        return data
    }

    func testSegmentedDownloadOverRealSockets() async throws {
        let content = payload(1 << 20)
        let server = try await LocalServer(handler: LocalServer.ranged(content))
        let out = directory.appendingPathComponent("out.bin")
        let link = URL(string: server.baseURL + "/f.bin?sign=live")!
        let task = try engine().makeTask(DownloadRequest(url: link, destination: out, cookies: [DownloadCookie(name: "a", value: "b")]))
        await task.start()
        let url = try await task.result()

        XCTAssertEqual(try Data(contentsOf: url), content)
        let ranged = server.requests.filter { $0.headers["range"] != "bytes=0-0" }
        XCTAssertGreaterThan(ranged.count, 1)
        for request in server.requests {
            XCTAssertEqual(request.path, "/f.bin?sign=live")
            XCTAssertEqual(request.headers["cookie"], "a=b")
            XCTAssertEqual(request.headers["accept-encoding"], "identity")
        }
    }

    func testServerWithoutRangesStreamsWholeBody() async throws {
        let content = payload(200_000)
        let server = try await LocalServer(handler: LocalServer.ranged(content, ranges: false))
        let out = directory.appendingPathComponent("out.bin")
        let task = try engine().makeTask(DownloadRequest(url: URL(string: server.baseURL + "/f")!, destination: out))
        await task.start()
        let url = try await task.result()
        XCTAssertEqual(try Data(contentsOf: url), content)
    }

    func testHtmlBodyIsRefusedOverTheWire() async throws {
        let server = try await LocalServer { _ in .init(status: 200, headers: ["Content-Type": "text/html"], body: Data("<html>".utf8)) }
        let out = directory.appendingPathComponent("out.bin")
        let task = try engine().makeTask(DownloadRequest(url: URL(string: server.baseURL + "/f")!, destination: out))
        await task.start()
        do {
            _ = try await task.result()
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? DownloadError, .htmlResponse)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    func testRedirectToAnotherOriginDropsCredentials() async throws {
        let target = try await LocalServer { _ in .init(body: Data("ok".utf8)) }
        let location = target.baseURL + "/landing"
        let origin = try await LocalServer { _ in .init(status: 302, headers: ["Location": location]) }
        let request = FetchRequest(url: URL(string: origin.baseURL + "/start")!, headers: ["Authorization": "t", "Cookie": "c", "X-Custom": "x"])
        let body = try await read(try URLSessionTransport().fetch(request))

        XCTAssertEqual(body, Data("ok".utf8))
        XCTAssertEqual(origin.requests.first?.headers["authorization"], "t")
        let landed = try XCTUnwrap(target.requests.first?.headers)
        XCTAssertNil(landed["authorization"])
        XCTAssertNil(landed["cookie"])
        XCTAssertNil(landed["x-custom"])
    }

    func testRedirectToSameOriginKeepsCredentials() async throws {
        let server = try await LocalServer { request in
            request.path == "/start" ? .init(status: 302, headers: ["Location": "/next"]) : .init(body: Data("ok".utf8))
        }
        let request = FetchRequest(url: URL(string: server.baseURL + "/start")!, headers: ["Authorization": "t"])
        _ = try await read(try URLSessionTransport().fetch(request))
        XCTAssertEqual(server.requests.last?.headers["authorization"], "t")
    }

    func testRedirectsCanBeLeftToTheCaller() async throws {
        let server = try await LocalServer { _ in .init(status: 302, headers: ["Location": "/next"]) }
        let response = try await URLSessionTransport().fetch(FetchRequest(url: URL(string: server.baseURL + "/start")!, followRedirects: false))
        XCTAssertEqual(response.info.statusCode, 302)
        XCTAssertEqual(response.info.headers["location"], "/next")
        XCTAssertEqual(server.requests.count, 1)
    }

    func testSlowReaderKeepsTheBufferBounded() async throws {
        let content = Data(repeating: 7, count: 64 << 20)
        let server = try await LocalServer(handler: LocalServer.ranged(content, ranges: false))
        let peak = PeakCounter()
        let limit = 1 << 20
        let transport = URLSessionTransport(maxBufferedBytes: limit) { peak.record($0) }
        let response = try await transport.fetch(FetchRequest(url: URL(string: server.baseURL + "/big")!))
        var total = 0
        for try await chunk in response.body {
            total += chunk.count
            // Slow until well past the mark, so URLSession has to pause to stay below it.
            if total < 16 << 20 { try await Task.sleep(for: .milliseconds(2)) }
        }
        XCTAssertEqual(total, content.count)
        XCTAssertGreaterThan(peak.value, 0)
        // One URLSession delivery can itself be megabytes, on top of the mark.
        XCTAssertLessThan(peak.value, 8 << 20, "peak \(peak.value)")
    }

    func testDroppingTheBodyEndsTheRequest() async throws {
        let server = try await LocalServer(handler: LocalServer.ranged(Data(repeating: 1, count: 32 << 20), ranges: false))
        do {
            let response = try await URLSessionTransport(maxBufferedBytes: 1 << 16).fetch(FetchRequest(url: URL(string: server.baseURL + "/big")!))
            XCTAssertEqual(response.info.statusCode, 200)
        }
        for _ in 0..<300 where server.brokenSends == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(server.brokenSends, 1, "the client closed before taking the whole body")
    }

    func testCancellingAReadStopsPromptly() async throws {
        let server = try await LocalServer(handler: LocalServer.ranged(Data(repeating: 1, count: 32 << 20), ranges: false))
        let url = URL(string: server.baseURL + "/big")!
        let reader = Task {
            let response = try await URLSessionTransport(maxBufferedBytes: 1 << 16).fetch(FetchRequest(url: url))
            var count = 0
            for try await chunk in response.body {
                count += chunk.count
                try await Task.sleep(for: .milliseconds(5))
            }
            return count
        }
        try await Task.sleep(for: .milliseconds(100))
        reader.cancel()
        let finished = await reader.result
        if case .success(let count) = finished { XCTAssertLessThan(count, 32 << 20) }
    }
}

private final class PeakCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var peak = 0
    var value: Int { lock.withLock { peak } }
    func record(_ count: Int) { lock.withLock { peak = max(peak, count) } }
}
