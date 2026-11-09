import Foundation
import XCTest
@testable import DownloadKit

private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func update(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}

final class HardeningTests: XCTestCase {
    private var directory: URL!
    private let source = URL(string: "https://example.test/file.bin")!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Hardening-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private var store: DownloadStore { DownloadStore(root: directory.appendingPathComponent("state")) }
    private var destination: URL { directory.appendingPathComponent("out/file.bin") }
    private func payload(_ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) }) }

    private func engine(
        _ transport: any DownloadTransport, concurrency: Int = 1, minimumSegment: Int64 = 1000,
        preemption: PreemptionPolicy = PreemptionPolicy(), limiter: DownloadSpeedLimiter? = nil,
        sleep: DownloadEngine.Sleep? = nil, clock: DownloadEngine.Clock? = nil
    ) -> DownloadEngine {
        DownloadEngine(
            configuration: DownloadConfiguration(
                concurrency: concurrency, minimumSegmentSize: minimumSegment, maxRetries: 1, progressInterval: 0,
                preemption: preemption, speedLimiter: limiter
            ),
            transport: transport, store: store, sleep: sleep ?? { _ in },
            clock: clock ?? { ProcessInfo.processInfo.systemUptime },
            // Tests drive ticks by hand.
            watchdogSleep: { _ in try await Task.sleep(for: .seconds(3600)) }
        )
    }

    private func assertFails(_ task: DownloadTask, with expected: DownloadError, line: UInt = #line) async {
        do {
            _ = try await task.result()
            XCTFail("expected \(expected)", line: line)
        } catch {
            XCTAssertEqual(error as? DownloadError, expected, line: line)
        }
    }

    // MARK: Content-Range

    func testContentRangeParsing() {
        XCTAssertEqual(HTTPRangePolicy.parse("bytes 0-0/10"), .init(start: 0, end: 0, total: 10))
        XCTAssertEqual(HTTPRangePolicy.parse(" BYTES  5-9/*"), .init(start: 5, end: 9, total: nil))
        for bad in [nil, "", "bytes", "bytes 5-4/10", "bytes 0-10/10", "bytes -1-4/10", "bytes 0-1", "items 0-1/2", "bytes0-1/2"] {
            XCTAssertNil(HTTPRangePolicy.parse(bad), bad ?? "nil")
        }
        XCTAssertTrue(HTTPRangePolicy.matches("bytes 5-9/10", start: 5, end: 9))
        XCTAssertTrue(HTTPRangePolicy.matches("bytes 5-9/10", start: 5, end: nil))
        XCTAssertFalse(HTTPRangePolicy.matches("bytes 5-8/10", start: 5, end: 9))
        XCTAssertFalse(HTTPRangePolicy.matches("bytes 4-9/10", start: 5, end: 9))
    }

    func testWrongContentRangeEndIsFatal() async throws {
        let content = payload(1000)
        let transport = FakeTransport(content: content) { request, _ in
            FakeTransport.response(status: 206, headers: ["Content-Range": "bytes 0-500/1000"], body: content.prefix(501))
        }
        let task = try engine(transport).makeTask(DownloadRequest(url: source, destination: destination))
        await task.start()
        await assertFails(task, with: .contentRangeMismatch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testChangedTotalIsReportedAsRemoteChange() async throws {
        let content = payload(1000)
        let transport = FakeTransport(content: content) { _, _ in
            FakeTransport.response(status: 206, headers: ["Content-Range": "bytes 0-999/2000"], body: content)
        }
        let task = try engine(transport).makeTask(DownloadRequest(url: source, destination: destination))
        await task.start()
        await assertFails(task, with: .remoteChanged)
    }

    func testHtmlPageIsNeverSaved() async throws {
        let transport = FakeTransport(content: payload(100)) { _, _ in
            FakeTransport.response(status: 206, headers: ["Content-Range": "bytes 0-99/100", "Content-Type": "text/html; charset=utf-8"], body: Data("<html>".utf8))
        }
        let task = try engine(transport).makeTask(DownloadRequest(url: source, destination: destination))
        await task.start()
        await assertFails(task, with: .htmlResponse)
    }

    // MARK: Hash resume

    func testFinishedSegmentsCarryHashesAndCorruptOneIsRefetched() async throws {
        let content = payload(1000)
        let id = UUID()
        let parts = [content.prefix(500), content.suffix(500)].map { Data($0) }
        try store.save(DownloadState(
            id: id, url: source, destination: destination, size: 1000, acceptsRanges: true, validator: "\"v1\"",
            segments: [
                Segment(id: 0, start: 0, end: 500, written: 500, sha256: sha256(parts[0])),
                Segment(id: 1, start: 500, end: 1000, written: 500, sha256: sha256(parts[1])),
            ]
        ))
        var bad = parts[1]
        bad[10] ^= 0xff
        try parts[0].write(to: store.partURL(id: id, segment: 0))
        try bad.write(to: store.partURL(id: id, segment: 1))

        let transport = FakeTransport(content: content)
        let task = try engine(transport).restore(id: id)
        await task.start()
        let url = try await task.result()
        XCTAssertEqual(try Data(contentsOf: url), content)
        XCTAssertEqual(transport.transfers.map(\.range), [500..<1000])
    }

    func testFullPartWithoutHashIsNotTrusted() async throws {
        let content = payload(500)
        let id = UUID()
        try store.save(DownloadState(
            id: id, url: source, destination: destination, size: 500, acceptsRanges: true, validator: "\"v1\"",
            segments: [Segment(id: 0, start: 0, end: 500, written: 500)]
        ))
        try Data(repeating: 0, count: 500).write(to: store.partURL(id: id, segment: 0))
        let transport = FakeTransport(content: content)
        let task = try engine(transport).restore(id: id)
        await task.start()
        let url = try await task.result()
        XCTAssertEqual(try Data(contentsOf: url), content)
        XCTAssertEqual(transport.transfers.map(\.range), [0..<500])
    }

    func testSealedSegmentsAreSavedAsTheyFinish() async throws {
        let content = payload(4000)
        // The second segment never ends, so the first must already be sealed on disk.
        let transport = FakeTransport(content: content) { request, _ in
            guard request.range?.lowerBound == 2000 else { return nil }
            return FakeTransport.stalling(status: 206, headers: ["Content-Range": "bytes 2000-3999/4000", "ETag": "\"v1\""], prefix: content.subdata(in: 2000..<2100))
        }
        let task = try engine(transport, concurrency: 2).makeTask(DownloadRequest(url: source, destination: destination))
        await task.start()
        let id = task.id
        let saved = store
        for _ in 0..<500 where (try? saved.load(id: id))?.segments.first?.sha256 == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(try store.load(id: id).segments.first?.sha256, sha256(content.prefix(2000)))
        await task.cancel()
    }

    func testMergeCatchesPartDamagedAfterSealing() throws {
        let part = directory.appendingPathComponent("0.part")
        try Data("bad".utf8).write(to: part)
        let segment = Segment(id: 0, start: 0, end: 3, written: 3, sha256: sha256(Data("abc".utf8)))
        XCTAssertThrowsError(try DownloadFinalizer.finalize(segments: [segment], size: 3, destination: destination) { _ in part }) {
            XCTAssertEqual($0 as? DownloadError, .corruptPart(segment: 0))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: part.path), "parts survive for a repair")
    }

    // MARK: Preemption

    func testFloorIsRelativeWithAbsoluteMinimum() {
        let policy = PreemptionPolicy()
        XCTAssertEqual(policy.floorBytesPerSecond(averagePerConnection: 0), 12 * 1024)
        XCTAssertEqual(policy.floorBytesPerSecond(averagePerConnection: 100_000), 50_000)
    }

    func testStalledConnectionIsReplacedWithoutBackoffAndKeepsBytes() async throws {
        let content = payload(4000)
        let now = Box<TimeInterval>(100)
        let sleeps = Box(0)
        let transport = FakeTransport(content: content) { request, index in
            guard index == 0 else { return nil }
            return FakeTransport.stalling(status: 206, headers: ["Content-Range": "bytes 0-3999/4000", "ETag": "\"v1\""], prefix: content.prefix(100))
        }
        let task = try engine(
            transport, sleep: { _ in sleeps.update { $0 += 1 } }, clock: { now.value }
        ).makeTask(DownloadRequest(url: source, destination: destination))
        await task.start()
        for _ in 0..<500 where transport.transfers.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        try await Task.sleep(for: .milliseconds(50))
        now.value += 4 // past the endgame minimum age
        await task.preemptSlowSegments()

        let url = try await task.result()
        XCTAssertEqual(try Data(contentsOf: url), content)
        XCTAssertEqual(transport.transfers.map(\.range), [0..<4000, 100..<4000])
        XCTAssertEqual(sleeps.value, 0)
    }

    func testWatchdogTicksOnItsOwnSleep() async throws {
        let content = payload(4000)
        let now = Box<TimeInterval>(100)
        let transport = FakeTransport(content: content) { request, index in
            guard index == 0 else { return nil }
            return FakeTransport.stalling(status: 206, headers: ["Content-Range": "bytes 0-3999/4000", "ETag": "\"v1\""], prefix: content.prefix(100))
        }
        let engine = DownloadEngine(
            configuration: DownloadConfiguration(concurrency: 1, minimumSegmentSize: 1000),
            transport: transport, store: store, sleep: { _ in XCTFail("no retry delay") }, clock: { now.value },
            watchdogSleep: { _ in
                now.update { $0 += 5 }
                try await Task.sleep(for: .milliseconds(5))
            }
        )
        let task = try engine.makeTask(DownloadRequest(url: source, destination: destination))
        await task.start()
        let url = try await task.result()
        XCTAssertEqual(try Data(contentsOf: url), content)
        XCTAssertEqual(transport.transfers.count, 2)
    }

    func testYoungAndFastConnectionsAreLeftAlone() async throws {
        let content = payload(4000)
        let now = Box<TimeInterval>(100)
        let transport = FakeTransport(content: content) { request, index in
            guard index == 0 else { return nil }
            return FakeTransport.stalling(status: 206, headers: ["Content-Range": "bytes 0-3999/4000", "ETag": "\"v1\""], prefix: content.prefix(100))
        }
        var policy = PreemptionPolicy()
        policy.endgameMinAge = 10
        let task = try engine(transport, preemption: policy, clock: { now.value })
            .makeTask(DownloadRequest(url: source, destination: destination))
        await task.start()
        for _ in 0..<500 where transport.transfers.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        try await Task.sleep(for: .milliseconds(50))
        now.value += 4
        await task.preemptSlowSegments()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(transport.transfers.count, 1)
        await task.cancel()
    }

    func testPreemptionStopsAtTheSegmentLimit() async throws {
        let content = payload(4000)
        let now = Box<TimeInterval>(100)
        let transport = FakeTransport(content: content) { request, _ in
            FakeTransport.stalling(status: 206, headers: ["Content-Range": "bytes 0-3999/4000", "ETag": "\"v1\""], prefix: Data())
        }
        var policy = PreemptionPolicy()
        policy.maxPerSegment = 2
        let task = try engine(transport, preemption: policy, clock: { now.value })
            .makeTask(DownloadRequest(url: source, destination: destination))
        await task.start()
        for expected in 1...4 {
            for _ in 0..<200 where transport.transfers.count < min(expected, 3) { try await Task.sleep(for: .milliseconds(2)) }
            try await Task.sleep(for: .milliseconds(20))
            now.value += 20
            await task.preemptSlowSegments()
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(transport.transfers.count, 3, "first connection plus two replacements")
        await task.cancel()
    }

    // MARK: Throttle

    func testLimiterPacesToTheRate() async throws {
        let now = Box<TimeInterval>(0)
        let waited = Box<Double>(0)
        let limiter = DownloadSpeedLimiter(limit: { 1000 }, clock: { now.value }, sleep: { duration in
            let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            XCTAssertLessThanOrEqual(seconds, 0.2)
            waited.update { $0 += seconds }
            now.update { $0 += seconds }
        })
        try await limiter.acquire(4000) // larger than the bucket, which holds one second
        XCTAssertEqual(waited.value, 4, accuracy: 0.3)
    }

    func testZeroLimitNeverWaits() async throws {
        let limiter = DownloadSpeedLimiter(limit: { 0 }, clock: { 0 }, sleep: { _ in XCTFail("must not wait") })
        try await limiter.acquire(1 << 40)
    }

    func testEngineGoesThroughTheLimiter() async throws {
        let now = Box<TimeInterval>(0)
        let waits = Box(0)
        let limiter = DownloadSpeedLimiter(limit: { 500 }, clock: { now.value }, sleep: { _ in
            waits.update { $0 += 1 }
            now.update { $0 += 0.2 }
        })
        let content = payload(1000)
        let task = try engine(FakeTransport(content: content), limiter: limiter)
            .makeTask(DownloadRequest(url: source, destination: destination))
        await task.start()
        let url = try await task.result()
        XCTAssertEqual(try Data(contentsOf: url), content)
        XCTAssertGreaterThan(waits.value, 0)
    }

    func testBodyBufferBlocksWriterAtTheMarkWithoutDroppingBytes() async throws {
        let buffer = BodyBuffer(highWater: 100)
        let peak = Box(0)
        let writer = Thread {
            for index in 0..<20 {
                let count = buffer.append(Data(repeating: UInt8(index), count: 30))
                peak.update { $0 = max($0, count) }
            }
            buffer.finish(throwing: nil)
        }
        writer.start()
        var read = Data()
        while let chunk = try await buffer.next() {
            read.append(chunk)
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(read.count, 600)
        XCTAssertEqual(read.last, 19)
        XCTAssertLessThanOrEqual(peak.value, 120)
    }

    func testClosingReleasesABlockedWriter() async {
        let buffer = BodyBuffer(highWater: 10)
        let released = expectation(description: "writer released")
        buffer.append(Data(count: 10))
        Thread {
            buffer.append(Data(count: 10))
            released.fulfill()
        }.start()
        buffer.close()
        await fulfillment(of: [released], timeout: 2)
    }

    func testBodyBufferDeliversFailureAfterTheBytes() async throws {
        let buffer = BodyBuffer(highWater: 100)
        buffer.append(Data([1]))
        buffer.finish(throwing: URLError(.networkConnectionLost))
        let first = try await buffer.next()
        XCTAssertEqual(first, Data([1]))
        do {
            _ = try await buffer.next()
            XCTFail("expected the failure")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }
    }

    // MARK: Link refresh

    private func expiring(_ content: Data, status: Int = 403) -> FakeTransport {
        FakeTransport(content: content) { request, _ in
            guard request.url.query == "sign=old" else { return nil }
            return FakeTransport.response(status: status, body: Data())
        }
    }

    func testExpiredLinkIsRefreshedAndResumesFromWrittenBytes() async throws {
        let content = payload(2000)
        let calls = Box<[LinkExpiry]>([])
        let fresh = URL(string: "https://example.test/file.bin?sign=new")!
        let transport = FakeTransport(content: content) { request, index in
            if index == 0 {
                let stream = AsyncThrowingStream<Data, Error> { continuation in
                    continuation.yield(content.prefix(700))
                    continuation.finish(throwing: URLError(.networkConnectionLost))
                }
                return FetchResponse(info: HTTPResponseInfo(statusCode: 206, headers: ["Content-Range": "bytes 0-1999/2000", "ETag": "\"v1\""]), body: stream)
            }
            if request.url.query == "sign=old" { return FakeTransport.response(status: 403, body: Data()) }
            return nil
        }
        let request = DownloadRequest(
            url: URL(string: "https://example.test/file.bin?sign=old")!, destination: destination,
            refreshLink: { expiry in
                calls.update { $0.append(expiry) }
                return RefreshedLink(url: fresh, headers: ["X-New": "1"])
            }
        )
        let task = try engine(transport).makeTask(request)
        await task.start()
        let url = try await task.result()
        XCTAssertEqual(try Data(contentsOf: url), content)
        XCTAssertEqual(calls.value.count, 1)
        XCTAssertEqual(calls.value.first?.statusCode, 403)
        XCTAssertNil(calls.value.first?.url.query, "the callback never sees the old token")
        XCTAssertEqual(transport.transfers.last?.range, 700..<2000)
        XCTAssertEqual(transport.transfers.last?.headers["X-New"], "1")
    }

    func testConcurrentWorkersShareOneRefresh() async throws {
        let content = payload(4000)
        let calls = Box(0)
        let request = DownloadRequest(
            url: URL(string: "https://example.test/file.bin?sign=ok")!, destination: destination,
            refreshLink: { _ in
                calls.update { $0 += 1 }
                try await Task.sleep(for: .milliseconds(20))
                return RefreshedLink(url: URL(string: "https://example.test/file.bin?sign=new")!)
            }
        )
        let transport = FakeTransport(content: content) { request, _ in
            request.url.query == "sign=new" ? nil : FakeTransport.response(status: 410, body: Data())
        }
        let task = try engine(transport, concurrency: 4).makeTask(request)
        await task.start()
        let url = try await task.result()
        XCTAssertEqual(try Data(contentsOf: url), content)
        XCTAssertEqual(calls.value, 1)
    }

    func testRefreshIsBoundedWhenNothingArrives() async throws {
        let calls = Box(0)
        let transport = FakeTransport(content: payload(100)) { _, _ in FakeTransport.response(status: 403, body: Data()) }
        let request = DownloadRequest(url: source, destination: destination, refreshLink: { _ in
            calls.update { $0 += 1 }
            return RefreshedLink(url: URL(string: "https://example.test/again")!)
        })
        let task = try engine(transport).makeTask(request)
        await task.start()
        await assertFails(task, with: .linkExpired)
        XCTAssertEqual(calls.value, 3)
    }

    func testBytesOnAnOlderLinkDoNotResetTheRefreshLimit() async throws {
        let content = payload(4000)
        let calls = Box(0)
        let transport = FakeTransport(content: content) { request, _ in
            guard let range = request.range else { return nil }
            if range.lowerBound >= 2000 { return FakeTransport.response(status: 403, body: Data()) }
            let headers = ["Content-Range": "bytes \(range.lowerBound)-\(range.upperBound - 1)/4000", "ETag": "\"v1\""]
            return FakeTransport.response(status: 206, headers: headers, body: content.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)), delayed: true)
        }
        let request = DownloadRequest(url: source, destination: destination, refreshLink: { _ in
            let count = calls.value + 1
            calls.value = count
            return RefreshedLink(url: URL(string: "https://example.test/file.bin?sign=\(count)")!)
        })
        let task = try engine(transport, concurrency: 2).makeTask(request)
        await task.start()
        await assertFails(task, with: .linkExpired)
        XCTAssertEqual(calls.value, 3)
    }

    func testRefresherReturningNothingFails() async throws {
        let request = DownloadRequest(url: source, destination: destination, refreshLink: { _ in nil })
        let transport = FakeTransport(content: payload(100)) { _, _ in FakeTransport.response(status: 404, body: Data()) }
        let task = try engine(transport).makeTask(request)
        await task.start()
        await assertFails(task, with: .linkExpired)
    }

    func testRefresherCannotInstallAnUnsafeLink() async throws {
        let request = DownloadRequest(url: source, destination: destination, refreshLink: { _ in
            RefreshedLink(url: URL(string: "file:///etc/passwd")!)
        })
        let transport = FakeTransport(content: payload(100)) { _, _ in FakeTransport.response(status: 403, body: Data()) }
        let task = try engine(transport).makeTask(request)
        await task.start()
        await assertFails(task, with: .unsupportedURL("only http and https are supported"))
    }

    func testWithoutRefresherStatusSurfacesUnchanged() async throws {
        let transport = FakeTransport(content: payload(100)) { _, _ in FakeTransport.response(status: 403, body: Data()) }
        let task = try engine(transport).makeTask(DownloadRequest(url: source, destination: destination))
        await task.start()
        await assertFails(task, with: .httpStatus(403))
    }

    // MARK: Tokens

    func testTokensNeverReachTheStateFile() async throws {
        let secret = "SECRETTOKEN"
        let link = URL(string: "https://example.test/file.bin?sign=\(secret)#\(secret)")!
        let content = payload(4000)
        let transport = FakeTransport(content: content) { request, index in
            guard index == 0 else { return nil }
            return FakeTransport.stalling(status: 206, headers: ["Content-Range": "bytes 0-3999/4000", "ETag": "\"v1\""], prefix: content.prefix(10))
        }
        let task = try engine(transport).makeTask(DownloadRequest(url: link, destination: destination, headers: ["Authorization": secret]))
        await task.start()
        for _ in 0..<500 where transport.transfers.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(transport.transfers.first?.url, link, "the live request still uses the signature")
        await task.pause()

        let raw = try String(contentsOf: store.stateURL(for: task.id), encoding: .utf8)
        XCTAssertFalse(raw.contains(secret))
        XCTAssertEqual(try store.load(id: task.id).linkIsRedacted, true)
        XCTAssertThrowsError(try engine(transport).restore(id: task.id)) {
            XCTAssertEqual($0 as? DownloadError, .linkRequired)
        }

        let restored = try engine(FakeTransport(content: content)).restore(id: task.id, url: link)
        await restored.start()
        let url = try await restored.result()
        XCTAssertEqual(try Data(contentsOf: url), content)
    }

    func testRestoreAsksTheRefresherForARedactedLink() async throws {
        let id = UUID()
        let content = payload(100)
        try store.save(DownloadState(
            id: id, url: URL(string: "https://example.test/f?sign=x")!, destination: destination,
            size: 100, acceptsRanges: true, validator: "\"v1\"", segments: [Segment(id: 0, start: 0, end: 100)]
        ))
        try Data().write(to: store.partURL(id: id, segment: 0))
        let transport = FakeTransport(content: content)
        let task = try engine(transport).restore(id: id, refreshLink: { _ in
            RefreshedLink(url: URL(string: "https://example.test/f?sign=new")!)
        })
        await task.start()
        _ = try await task.result()
        XCTAssertTrue(transport.requests.allSatisfy { $0.url.query == "sign=new" })
    }

    func testFinishedPartsMergeWithoutTheNetwork() async throws {
        let id = UUID()
        let content = payload(100)
        try store.prepareDirectory(for: id)
        try content.prefix(60).write(to: store.partURL(id: id, segment: 0))
        try content.suffix(40).write(to: store.partURL(id: id, segment: 1))
        let first = try PartHash.hash(of: store.partURL(id: id, segment: 0), length: 60)
        let second = try PartHash.hash(of: store.partURL(id: id, segment: 1), length: 40)
        try store.save(DownloadState(
            id: id, url: URL(string: "https://example.test/f?sign=x")!, destination: destination,
            size: 100, acceptsRanges: true, validator: "\"v1\"",
            segments: [Segment(id: 0, start: 0, end: 60, written: 60, sha256: first),
                       Segment(id: 1, start: 60, end: 100, written: 40, sha256: second)]
        ))
        let transport = FakeTransport(content: content)
        let task = try engine(transport).restore(id: id, refreshLink: { _ in throw DownloadError.linkRequired })
        await task.start()
        let url = try await task.result()
        XCTAssertEqual(try Data(contentsOf: url), content)
        XCTAssertTrue(transport.requests.isEmpty, "an expired link must not block a finished download")
    }

    func testOldStateFileLosesItsTokenOnLoad() throws {
        var state = DownloadState(id: UUID(), url: source, destination: destination, size: nil, acceptsRanges: false, validator: nil, segments: [])
        state.url = URL(string: "https://example.test/f?sign=x")!
        try store.prepareDirectory(for: state.id)
        try JSONEncoder().encode(state).write(to: store.stateURL(for: state.id))
        let loaded = try store.load(id: state.id)
        XCTAssertNil(loaded.url.query)
        XCTAssertEqual(loaded.linkIsRedacted, true)
    }
}
