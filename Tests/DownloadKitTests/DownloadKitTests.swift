import Foundation
import XCTest
@testable import DownloadKit

/// Serves `content` from memory and records every request. Never touches the network.
final class FakeTransport: DownloadTransport, @unchecked Sendable {
    typealias Override = @Sendable (FetchRequest, Int) throws -> FetchResponse?

    let content: Data
    let supportsRanges: Bool
    let validator: String?
    let chunkSize: Int
    /// Runs before the default behaviour for non-probe requests; second argument is the call index.
    let override: Override?
    /// Delay between chunks of ranges starting in this interval, to simulate a slow connection.
    let slowFrom: Int64?

    private let lock = NSLock()
    private var recorded: [FetchRequest] = []

    init(
        content: Data, supportsRanges: Bool = true, validator: String? = "\"v1\"", chunkSize: Int = 16,
        slowFrom: Int64? = nil, override: Override? = nil
    ) {
        self.content = content
        self.supportsRanges = supportsRanges
        self.validator = validator
        self.chunkSize = chunkSize
        self.slowFrom = slowFrom
        self.override = override
    }

    var requests: [FetchRequest] { lock.withLock { recorded } }
    /// Everything except the one-byte probes.
    var transfers: [FetchRequest] { requests.filter { $0.range != 0..<1 } }

    func fetch(_ request: FetchRequest) async throws -> FetchResponse {
        let index = lock.withLock { () -> Int in
            recorded.append(request)
            return recorded.filter { $0.range != 0..<1 }.count - 1
        }
        if request.range != 0..<1, let response = try override?(request, index) { return response }

        var headers: [String: String] = [:]
        if let validator { headers["ETag"] = validator }
        guard supportsRanges, let range = request.range else {
            headers["Content-Length"] = "\(content.count)"
            return Self.response(status: 200, headers: headers, body: content, chunkSize: chunkSize)
        }
        let upper = min(range.upperBound, Int64(content.count))
        headers["Content-Range"] = "bytes \(range.lowerBound)-\(upper - 1)/\(content.count)"
        let slice = content.subdata(in: Int(range.lowerBound)..<Int(upper))
        let delay = slowFrom.map { range.lowerBound >= $0 } ?? false
        return Self.response(status: 206, headers: headers, body: slice, chunkSize: chunkSize, delayed: delay)
    }

    static func response(status: Int, headers: [String: String] = [:], body: Data, chunkSize: Int = 16, delayed: Bool = false) -> FetchResponse {
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                var index = 0
                while index < body.count, !Task.isCancelled {
                    if delayed { try? await Task.sleep(for: .milliseconds(1)) }
                    let end = min(index + chunkSize, body.count)
                    continuation.yield(body.subdata(in: index..<end))
                    index = end
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return FetchResponse(info: HTTPResponseInfo(statusCode: status, headers: headers), body: stream)
    }

    /// Sends `prefix`, then hangs until the consumer goes away.
    static func stalling(status: Int, headers: [String: String], prefix: Data) -> FetchResponse {
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(prefix)
        }
        return FetchResponse(info: HTTPResponseInfo(statusCode: status, headers: headers), body: stream)
    }
}

final class DownloadKitTests: XCTestCase {
    private var directory: URL!
    private let source = URL(string: "https://example.test/file.bin")!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private var store: DownloadStore { DownloadStore(root: directory.appendingPathComponent("state")) }
    private var destination: URL { directory.appendingPathComponent("out/file.bin") }

    private func payload(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) })
    }

    private func engine(
        _ transport: FakeTransport, concurrency: Int = 4, minimumSegment: Int64 = 50, maxRetries: Int = 2,
        sleep: DownloadEngine.Sleep? = nil
    ) -> DownloadEngine {
        DownloadEngine(
            configuration: DownloadConfiguration(concurrency: concurrency, minimumSegmentSize: minimumSegment, maxRetries: maxRetries, progressInterval: 0),
            transport: transport, store: store, sleep: sleep ?? { _ in }
        )
    }

    private func run(_ engine: DownloadEngine, headers: [String: String] = [:]) async throws -> URL {
        let task = try engine.makeTask(DownloadRequest(url: source, destination: destination, headers: headers))
        await task.start()
        return try await task.result()
    }

    private func assertFails(_ task: DownloadTask, with expected: DownloadError, line: UInt = #line) async {
        do {
            let url = try await task.result()
            XCTFail("expected \(expected), finished at \(url)", line: line)
        } catch {
            XCTAssertEqual(error as? DownloadError, expected, line: line)
        }
    }

    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    // MARK: Chain selection

    func testChainWithoutOverlap() throws {
        let segments = [Segment(id: 0, start: 0, end: 50, written: 50), Segment(id: 1, start: 50, end: 100, written: 50)]
        XCTAssertEqual(try SegmentChain.select(segments: segments, size: 100).get(), [
            ChainLink(segmentID: 0, skip: 0, length: 50), ChainLink(segmentID: 1, skip: 0, length: 50),
        ])
    }

    func testChainTrimsOverlapAndPrefersFurthestReach() throws {
        let segments = [
            Segment(id: 0, start: 0, end: 60, written: 60),
            Segment(id: 1, start: 10, end: 30, written: 20), // contained: never used
            Segment(id: 2, start: 40, end: 90, written: 50),
            Segment(id: 3, start: 50, end: 100, written: 50),
        ]
        XCTAssertEqual(try SegmentChain.select(segments: segments, size: 100).get(), [
            ChainLink(segmentID: 0, skip: 0, length: 60),
            ChainLink(segmentID: 3, skip: 10, length: 40),
        ])
    }

    func testChainReportsGapBetweenSegments() {
        let segments = [Segment(id: 0, start: 0, end: 40, written: 30), Segment(id: 1, start: 50, end: 100, written: 50)]
        XCTAssertEqual(SegmentChain.select(segments: segments, size: 100), .failure(.incompleteData(gap: 30..<50)))
    }

    func testChainReportsMissingTailAndEmptyPlan() {
        XCTAssertEqual(
            SegmentChain.select(segments: [Segment(id: 0, start: 0, end: 80, written: 80)], size: 100),
            .failure(.incompleteData(gap: 80..<100))
        )
        XCTAssertEqual(SegmentChain.select(segments: [], size: 10), .failure(.incompleteData(gap: 0..<10)))
        XCTAssertEqual(SegmentChain.select(segments: [], size: 0), .success([]))
    }

    func testMergedBytesFollowTheChainThroughOverlap() throws {
        let content = payload(100)
        let id = UUID()
        try store.prepareDirectory(for: id)
        try content.prefix(60).write(to: store.partURL(id: id, segment: 0))
        try content.subdata(in: 40..<100).write(to: store.partURL(id: id, segment: 1))
        let segments = [Segment(id: 0, start: 0, end: 60, written: 60), Segment(id: 1, start: 40, end: 100, written: 60)]
        let url = try DownloadFinalizer.finalize(segments: segments, size: 100, destination: destination) {
            store.partURL(id: id, segment: $0)
        }
        XCTAssertEqual(try Data(contentsOf: url), content)
    }

    // MARK: Happy paths

    func testSegmentedDownloadUsesConcurrentRanges() async throws {
        let content = payload(1000)
        let transport = FakeTransport(content: content)
        // Segments of exactly the minimum size are too small to re-split, so the plan is exact.
        let url = try await run(engine(transport, concurrency: 4, minimumSegment: 250))
        XCTAssertEqual(url, destination)
        XCTAssertEqual(try Data(contentsOf: url), content)
        XCTAssertEqual(Set(transport.transfers.compactMap(\.range)), [0..<250, 250..<500, 500..<750, 750..<1000])
        XCTAssertTrue(store.list().isEmpty, "state is removed after success")
    }

    func testIdleConnectionTakesOverHalfOfSlowSegment() async throws {
        let content = payload(4000)
        // The second half is slow: the fast worker finishes first and must steal from it.
        let transport = FakeTransport(content: content, slowFrom: 2000)
        let url = try await run(engine(transport, concurrency: 2, minimumSegment: 100))
        XCTAssertEqual(try Data(contentsOf: url), content)
        XCTAssertGreaterThan(transport.transfers.count, 2, "a re-split adds a request")
    }

    func testCustomHeadersAndCookiesReachEveryRequest() async throws {
        let transport = FakeTransport(content: payload(200))
        let task = try engine(transport).makeTask(DownloadRequest(
            url: source, destination: destination, headers: ["X-Token": "abc"],
            cookies: [DownloadCookie(name: "sid", value: "1"), DownloadCookie(name: "k", value: "2")]
        ))
        await task.start()
        _ = try await task.result()
        XCTAssertFalse(transport.requests.isEmpty)
        for request in transport.requests {
            XCTAssertEqual(request.headers["X-Token"], "abc")
            XCTAssertEqual(request.headers["Cookie"], "sid=1; k=2")
        }
    }

    func testRejectsHeaderInjectionAndUrlCredentials() {
        let engine = engine(FakeTransport(content: Data()))
        XCTAssertThrowsError(try engine.makeTask(DownloadRequest(url: source, destination: destination, headers: ["X": "a\r\nEvil: 1"])))
        XCTAssertThrowsError(try engine.makeTask(DownloadRequest(url: URL(string: "https://u:p@example.test/f")!, destination: destination)))
        XCTAssertThrowsError(try engine.makeTask(DownloadRequest(url: URL(string: "file:///etc/hosts")!, destination: destination)))
    }

    func testProgressStreamEndsWithCompletion() async throws {
        let content = payload(500)
        let task = try engine(FakeTransport(content: content)).makeTask(DownloadRequest(url: source, destination: destination))
        await task.start()
        var last: DownloadProgress?
        for await event in task.progress { last = event }
        XCTAssertEqual(last?.phase, .completed(destination))
        XCTAssertEqual(last?.receivedBytes, 500)
        XCTAssertEqual(last?.totalBytes, 500)
    }

    // MARK: No-Range fallback

    func testNoRangeServerUsesSingleStream() async throws {
        let content = payload(400)
        let transport = FakeTransport(content: content, supportsRanges: false)
        let url = try await run(engine(transport))
        XCTAssertEqual(try Data(contentsOf: url), content)
        XCTAssertEqual(transport.transfers.count, 1)
        XCTAssertNil(transport.transfers[0].range)
    }

    func testUnknownLengthStreamCompletes() async throws {
        let content = payload(300)
        let transport = FakeTransport(content: content, supportsRanges: false, override: { _, _ in
            FakeTransport.response(status: 200, body: content)
        })
        let url = try await run(engine(transport))
        XCTAssertEqual(try Data(contentsOf: url), content)
    }

    func testServerIgnoringRangeMidDownloadFallsBackToSingleStream() async throws {
        let content = payload(400)
        let transport = FakeTransport(content: content, override: { request, _ in
            request.range == nil ? nil : FakeTransport.response(status: 200, headers: ["Content-Length": "400"], body: content)
        })
        let url = try await run(engine(transport))
        XCTAssertEqual(try Data(contentsOf: url), content)
        XCTAssertEqual(transport.transfers.last?.range, nil)
    }

    // MARK: Resume

    func testRestoreAfterRestartRequestsOnlyMissingBytes() async throws {
        let content = payload(1000)
        let id = UUID()
        try store.save(DownloadState(
            id: id, url: source, destination: destination, size: 1000, acceptsRanges: true, validator: "\"v1\"",
            // `written` is stale on purpose: as after a crash, the part files are the truth.
            segments: [Segment(id: 0, start: 0, end: 500, written: 0), Segment(id: 1, start: 500, end: 1000, written: 0)]
        ))
        try content.prefix(300).write(to: store.partURL(id: id, segment: 0))
        try content.subdata(in: 500..<1000).write(to: store.partURL(id: id, segment: 1))

        let transport = FakeTransport(content: content)
        // A large minimum disables re-splitting, so the single remaining range is exact.
        let engine = engine(transport, minimumSegment: 1000)
        XCTAssertEqual(engine.savedDownloads().map(\.id), [id])
        let task = try engine.restore(id: id, headers: ["X-Token": "fresh"])
        await task.start()
        let url = try await task.result()

        XCTAssertEqual(try Data(contentsOf: url), content)
        XCTAssertEqual(transport.transfers.map(\.range), [300..<500])
        XCTAssertEqual(transport.transfers.first?.headers["X-Token"], "fresh")
    }

    func testRestoreRestartsWhenRemoteChanged() async throws {
        let content = payload(400)
        let id = UUID()
        try store.save(DownloadState(
            id: id, url: source, destination: destination, size: 400, acceptsRanges: true, validator: "\"old\"",
            segments: [Segment(id: 0, start: 0, end: 400, written: 100)]
        ))
        try Data(repeating: 0xEE, count: 100).write(to: store.partURL(id: id, segment: 0))
        let transport = FakeTransport(content: content)
        let task = try engine(transport).restore(id: id)
        await task.start()
        let url = try await task.result()
        XCTAssertEqual(try Data(contentsOf: url), content, "stale bytes must not survive")
    }

    func testPauseThenResumeInProcess() async throws {
        let content = payload(400)
        let gate = Gate()
        let transport = FakeTransport(content: content, override: { request, index in
            guard index == 0, let range = request.range else { return nil }
            gate.open()
            return FakeTransport.stalling(
                status: 206,
                headers: ["Content-Range": "bytes \(range.lowerBound)-\(range.upperBound - 1)/400", "ETag": "\"v1\""],
                prefix: content.subdata(in: Int(range.lowerBound)..<Int(range.lowerBound) + 40)
            )
        })
        let engine = engine(transport, concurrency: 1, minimumSegment: 400)
        let task = try engine.makeTask(DownloadRequest(url: source, destination: destination))
        await task.start()
        await gate.wait()
        // Wait until the prefix has reached the part file, then pause.
        let part = store.partURL(id: task.id, segment: 0)
        while ((try? Data(contentsOf: part))?.count ?? 0) < 40 { try await Task.sleep(for: .milliseconds(1)) }
        await task.pause()
        XCTAssertEqual(try store.load(id: task.id).segments.first?.written, 40)

        await task.start()
        let url = try await task.result()
        XCTAssertEqual(try Data(contentsOf: url), content)
        XCTAssertEqual(transport.transfers.last?.range, 40..<400)
    }

    func testCancelDeletesPartsAndState() async throws {
        let content = payload(400)
        let transport = FakeTransport(content: content, override: { request, _ in
            guard let range = request.range else { return nil }
            return FakeTransport.stalling(status: 206, headers: ["Content-Range": "bytes \(range.lowerBound)-\(range.upperBound - 1)/400"], prefix: Data([1]))
        })
        let task = try engine(transport, concurrency: 1).makeTask(DownloadRequest(url: source, destination: destination))
        await task.start()
        while transport.transfers.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
        await task.cancel()
        await assertFails(task, with: .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(for: task.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: Persistence

    func testStateIsPrivateAndHoldsNoCredentials() async throws {
        let content = payload(200)
        let transport = FakeTransport(content: content, override: { _, _ in throw DownloadError.httpStatus(403) })
        let task = try engine(transport).makeTask(DownloadRequest(
            url: source, destination: destination, headers: ["Authorization": "Bearer SECRET-TOKEN"],
            cookies: [DownloadCookie(name: "sid", value: "SECRET-COOKIE")]
        ))
        await task.start()
        await assertFails(task, with: .httpStatus(403))

        let stateURL = store.stateURL(for: task.id)
        let text = try String(contentsOf: stateURL, encoding: .utf8)
        XCTAssertFalse(text.contains("SECRET"))
        XCTAssertEqual(try permissions(stateURL), 0o600)
        XCTAssertEqual(try permissions(store.partURL(id: task.id, segment: 0)), 0o600)
        XCTAssertEqual(try permissions(store.directory(for: task.id)), 0o700)
        XCTAssertEqual(try permissions(store.root), 0o700)
    }

    func testCorruptStateIsReported() throws {
        let id = UUID()
        try store.prepareDirectory(for: id)
        try Data("nope".utf8).write(to: store.stateURL(for: id))
        XCTAssertThrowsError(try store.load(id: id)) { error in
            guard case .stateCorrupt = error as? DownloadError else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(store.list().isEmpty)
    }

    // MARK: Retry

    func testRetryExhaustionIsBoundedAndBacksOff() async throws {
        let transport = FakeTransport(content: payload(100), override: { _, _ in throw URLError(.timedOut) })
        let delays = DelayLog()
        let engine = engine(transport, concurrency: 1, maxRetries: 3, sleep: { await delays.add($0) })
        let task = try engine.makeTask(DownloadRequest(url: source, destination: destination))
        await task.start()
        do {
            _ = try await task.result()
            XCTFail("expected failure")
        } catch DownloadError.retriesExhausted(let attempts, _) {
            XCTAssertEqual(attempts, 4)
        }
        XCTAssertEqual(transport.transfers.count, 4, "first try plus three retries")
        let recorded = await delays.values
        XCTAssertEqual(recorded, [.milliseconds(500), .seconds(1), .seconds(2)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testTransientFailureRecovers() async throws {
        let content = payload(200)
        let transport = FakeTransport(content: content, override: { _, index in
            if index == 0 { throw DownloadError.httpStatus(503) }
            return nil
        })
        let url = try await run(engine(transport, concurrency: 1))
        XCTAssertEqual(try Data(contentsOf: url), content)
    }

    func testPermanentHttpErrorIsNotRetried() async throws {
        let transport = FakeTransport(content: payload(100), override: { _, _ in
            FakeTransport.response(status: 404, body: Data())
        })
        let task = try engine(transport, concurrency: 1).makeTask(DownloadRequest(url: source, destination: destination))
        await task.start()
        await assertFails(task, with: .httpStatus(404))
        XCTAssertEqual(transport.transfers.count, 1)
    }

    func testRemoteChangeMidDownloadFails() async throws {
        let transport = FakeTransport(content: payload(100), override: { request, _ in
            guard let range = request.range else { return nil }
            return FakeTransport.response(status: 206, headers: [
                "Content-Range": "bytes \(range.lowerBound)-\(range.upperBound - 1)/100", "ETag": "\"v2\"",
            ], body: Data(count: 100))
        })
        let task = try engine(transport, concurrency: 1).makeTask(DownloadRequest(url: source, destination: destination))
        await task.start()
        await assertFails(task, with: .remoteChanged)
    }

    // MARK: Size

    func testShortBodyWithoutRangesFailsAsSizeMismatchAfterBoundedRetries() async throws {
        let content = payload(100)
        let transport = FakeTransport(content: content, supportsRanges: false, override: { _, _ in
            FakeTransport.response(status: 200, body: content.prefix(80))
        })
        let task = try engine(transport, maxRetries: 2).makeTask(DownloadRequest(url: source, destination: destination))
        await task.start()
        await assertFails(task, with: .sizeMismatch(expected: 100, actual: 80))
        XCTAssertEqual(transport.transfers.count, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testOversizedBodyWithoutRangesFails() async throws {
        let transport = FakeTransport(content: payload(100), supportsRanges: false, chunkSize: 1000, override: { _, _ in
            FakeTransport.response(status: 200, body: Data(count: 150), chunkSize: 1000)
        })
        let task = try engine(transport).makeTask(DownloadRequest(url: source, destination: destination))
        await task.start()
        await assertFails(task, with: .sizeMismatch(expected: 100, actual: 150))
    }

    func testFinalizerRejectsPartShorterThanRecordedAndKeepsIt() throws {
        let id = UUID()
        try store.prepareDirectory(for: id)
        let part = store.partURL(id: id, segment: 0)
        try payload(70).write(to: part)
        let segments = [Segment(id: 0, start: 0, end: 100, written: 100)]
        XCTAssertThrowsError(try DownloadFinalizer.finalize(segments: segments, size: 100, destination: destination) { _ in part }) { error in
            XCTAssertEqual(error as? DownloadError, .sizeMismatch(expected: 100, actual: 70))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path), [], "temp file removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: part.path))
    }

    func testFinalizerFailsWithGapOnIncompleteData() throws {
        let segments = [Segment(id: 0, start: 0, end: 50, written: 20), Segment(id: 1, start: 50, end: 100, written: 50)]
        XCTAssertThrowsError(try DownloadFinalizer.finalize(segments: segments, size: 100, destination: destination) { _ in self.directory }) { error in
            XCTAssertEqual(error as? DownloadError, .incompleteData(gap: 20..<50))
        }
    }

    // MARK: Name collision

    func testExistingFileIsNeverOverwritten() async throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("keep me".utf8)
        try original.write(to: destination)
        let taken = destination.deletingLastPathComponent().appendingPathComponent("file (1).bin")
        try original.write(to: taken)

        let content = payload(200)
        let url = try await run(engine(FakeTransport(content: content)))

        XCTAssertEqual(url.lastPathComponent, "file (2).bin")
        XCTAssertEqual(try Data(contentsOf: url), content)
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertEqual(try Data(contentsOf: taken), original)
    }

    func testUniqueNameWithoutExtension() {
        let plain = URL(fileURLWithPath: "/tmp/archive")
        XCTAssertEqual(DownloadFinalizer.uniqueName(for: plain, index: 0), plain)
        XCTAssertEqual(DownloadFinalizer.uniqueName(for: plain, index: 3).lastPathComponent, "archive (3)")
    }

    // MARK: Transport

    func testRequestBuilderUsesInclusiveRangeAndIdentityEncoding() {
        let request = URLSessionTransport.makeRequest(FetchRequest(url: source, headers: ["X-A": "1", "range": "bytes=9-"], range: 10..<20))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=10-19")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-A"), "1")
        XCTAssertFalse(request.httpShouldHandleCookies)
    }

    func testRedirectKeepsCredentialsOnlyOnSameOrigin() throws {
        var original = URLRequest(url: source)
        original.setValue("secret", forHTTPHeaderField: "Cookie")
        func proposal(_ url: String) -> URLRequest {
            var request = URLRequest(url: URL(string: url)!)
            request.setValue("secret", forHTTPHeaderField: "Cookie")
            request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
            return request
        }
        let same = URLSessionTransport.redirectRequest(original: original, proposed: proposal("https://example.test/other"))
        XCTAssertEqual(same?.value(forHTTPHeaderField: "Cookie"), "secret")
        let other = try XCTUnwrap(URLSessionTransport.redirectRequest(original: original, proposed: proposal("https://cdn.test/f")))
        XCTAssertNil(other.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(other.value(forHTTPHeaderField: "Range"), "bytes=0-1")
        XCTAssertNil(URLSessionTransport.redirectRequest(original: original, proposed: proposal("http://example.test/f")))
    }

    func testResponseParsing() {
        let info = HTTPResponseInfo(statusCode: 206, headers: ["Content-Range": "bytes 5-9/100", "ETag": "W/\"x\"", "Last-Modified": "then"])
        XCTAssertEqual(info.contentRange?.start, 5)
        XCTAssertEqual(info.contentRange?.total, 100)
        XCTAssertEqual(info.validator, "then")
        XCTAssertNil(HTTPResponseInfo(statusCode: 206, headers: ["Content-Range": "bytes 0-0/*"]).contentRange?.total)
        XCTAssertTrue(HTTPResponseInfo(statusCode: 200, headers: ["Content-Encoding": "gzip"]).isEncoded)
    }
}

private actor DelayLog {
    private(set) var values: [Duration] = []
    func add(_ value: Duration) { values.append(value) }
}

/// A one-shot signal from a synchronous transport override to an async test.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false

    func open() { lock.withLock { opened = true } }

    func wait() async {
        while !lock.withLock({ opened }) {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}
