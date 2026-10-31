import Foundation

/// Creates and restores tasks. Everything external is injected so tests touch no network,
/// no real clock and no real Application Support directory.
public struct DownloadEngine: Sendable {
    public typealias Sleep = @Sendable (Duration) async throws -> Void
    public typealias Clock = @Sendable () -> TimeInterval

    let configuration: DownloadConfiguration
    let transport: any DownloadTransport
    let store: DownloadStore
    let sleep: Sleep
    let clock: Clock

    public init(
        configuration: DownloadConfiguration = DownloadConfiguration(),
        transport: any DownloadTransport = URLSessionTransport(),
        store: DownloadStore,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        clock: @escaping Clock = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.configuration = configuration
        self.transport = transport
        self.store = store
        self.sleep = sleep
        self.clock = clock
    }

    /// Uses `Application Support/Thermo/Downloads`.
    public init(configuration: DownloadConfiguration = DownloadConfiguration()) throws {
        self.init(configuration: configuration, store: DownloadStore(root: try DownloadStore.defaultRoot()))
    }

    public func makeTask(_ request: DownloadRequest) throws -> DownloadTask {
        guard let scheme = request.url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw DownloadError.unsupportedURL("only http and https are supported")
        }
        guard request.url.user == nil, request.url.password == nil else {
            // The URL is persisted, so credentials have to travel in headers instead.
            throw DownloadError.unsupportedURL("credentials in the url; pass them as headers")
        }
        let state = DownloadState(
            id: UUID(), url: request.url, destination: request.destination,
            size: nil, acceptsRanges: false, validator: nil, segments: []
        )
        return DownloadTask(engine: self, state: state, isRestored: false, headers: try Self.requestHeaders(request.headers, request.cookies))
    }

    /// Rebuilds a task from its state file. Credentials were never saved, so pass them again.
    public func restore(id: UUID, headers: [String: String] = [:], cookies: [DownloadCookie] = []) throws -> DownloadTask {
        let state = try store.load(id: id)
        return DownloadTask(engine: self, state: state, isRestored: true, headers: try Self.requestHeaders(headers, cookies))
    }

    public func savedDownloads() -> [DownloadState] {
        store.list()
    }

    static func requestHeaders(_ headers: [String: String], _ cookies: [DownloadCookie]) throws -> [String: String] {
        let forbidden = CharacterSet(charactersIn: "\r\n\0")
        func isValid(_ text: String) -> Bool { text.rangeOfCharacter(from: forbidden) == nil }
        var result: [String: String] = [:]
        for (name, value) in headers {
            guard !name.isEmpty, isValid(name), isValid(value) else { throw DownloadError.invalidHeader(name) }
            result[name] = value
        }
        for cookie in cookies {
            guard isValid(cookie.name), isValid(cookie.value), !cookie.name.contains(";"), !cookie.value.contains(";") else {
                throw DownloadError.invalidHeader("Cookie")
            }
        }
        if !cookies.isEmpty {
            let joined = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            let existing = result.first { $0.key.caseInsensitiveCompare("Cookie") == .orderedSame }
            if let existing { result[existing.key] = nil }
            result["Cookie"] = existing.map { "\($0.value); \(joined)" } ?? joined
        }
        return result
    }
}

/// One download. All state lives on the actor; workers run off it and only hop back to record.
///
/// The state file carries the plan (segment boundaries). Part-file lengths are the truth for
/// how much was written, which is why a crash between saves loses nothing.
public actor DownloadTask {
    private enum Intent { case none, pause, cancel }
    /// A clean EOF before the expected end. Retried; surfaces as `sizeMismatch` if it persists.
    private struct ShortBody: Error { let expected: Int64; let actual: Int64 }

    public nonisolated let id: UUID
    /// Ends after the task completes, fails or is cancelled. Keeps only the newest unread event.
    public nonisolated let progress: AsyncStream<DownloadProgress>

    private nonisolated let engine: DownloadEngine
    private nonisolated let url: URL
    private nonisolated let headers: [String: String]
    private let continuation: AsyncStream<DownloadProgress>.Continuation
    private var state: DownloadState
    private var hasPlan: Bool
    private var active = Set<Int>()
    private var runTask: Task<Void, Never>?
    private var intent = Intent.none
    private var outcome: Result<URL, DownloadError>?
    private var waiters: [CheckedContinuation<URL, Error>] = []
    private var phase = DownloadPhase.probing
    private var samples: [(time: TimeInterval, bytes: Int64)] = []
    private var lastEmit: TimeInterval = -.infinity

    init(engine: DownloadEngine, state: DownloadState, isRestored: Bool, headers: [String: String]) {
        self.engine = engine
        self.state = state
        self.hasPlan = isRestored
        self.url = state.url
        self.headers = headers
        self.id = state.id
        let (stream, continuation) = AsyncStream<DownloadProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.progress = stream
        self.continuation = continuation
    }

    // MARK: Control

    /// Starts, or continues after `pause()`. Does nothing while running or once finished.
    public func start() {
        guard runTask == nil, outcome == nil else { return }
        intent = .none
        runTask = Task { await self.run() }
    }

    /// Stops all connections and saves the state. Returns once everything has stopped.
    public func pause() async {
        guard let runTask else { return }
        intent = .pause
        runTask.cancel()
        await runTask.value
    }

    /// Stops the task and deletes its parts and state. Also clears up after a failure.
    public func cancel() async {
        if case .success = outcome { return }
        if outcome != nil {
            engine.store.remove(id: id)
            return
        }
        if let runTask {
            intent = .cancel
            runTask.cancel()
            await runTask.value
        }
        if outcome == nil {
            engine.store.remove(id: id)
            phase = .cancelled
            conclude(.failure(.cancelled))
        }
    }

    /// Waits for the terminal outcome; a pause alone does not end the wait.
    public func result() async throws -> URL {
        if let outcome { return try outcome.get() }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    // MARK: Run

    private func run() async {
        do {
            try await prepare()
            while true {
                do {
                    try await downloadSegments()
                    break
                } catch DownloadError.rangeNotHonored where state.acceptsRanges {
                    // The probe promised ranges but a real request ignored them.
                    try plan(size: state.size, acceptsRanges: false, validator: state.validator)
                }
            }
            try Task.checkCancellation()
            setPhase(.merging)
            let finished = try await merge()
            engine.store.remove(id: id)
            phase = .completed(finished)
            conclude(.success(finished))
        } catch {
            finishRun(with: error)
        }
        runTask = nil
    }

    private func finishRun(with error: Error) {
        switch intent {
        case .pause:
            try? engine.store.save(state)
            setPhase(.paused)
        case .cancel:
            break // cancel() deletes everything once this run has stopped
        case .none:
            try? engine.store.save(state)
            let failure = error as? DownloadError ?? .io(error.localizedDescription)
            phase = .failed(failure.localizedDescription)
            conclude(.failure(failure))
        }
    }

    private func merge() async throws -> URL {
        // A finished stream of unknown length has no plan-time size.
        let size = state.size ?? state.segments.first?.written ?? 0
        let segments = state.segments
        let destination = state.destination
        let store = engine.store
        let taskID = id
        return try await Task.detached {
            try DownloadFinalizer.finalize(segments: segments, size: size, destination: destination) {
                store.partURL(id: taskID, segment: $0)
            }
        }.value
    }

    private func conclude(_ result: Result<URL, DownloadError>) {
        outcome = result
        continuation.yield(snapshot())
        continuation.finish()
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume(with: result) }
    }

    // MARK: Planning

    private func prepare() async throws {
        setPhase(.probing)
        let probe = try await probeRemote()
        if hasPlan, !state.segments.isEmpty, state.acceptsRanges, probe.acceptsRanges, probe.size == state.size,
           state.validator == nil || probe.validator == nil || state.validator == probe.validator {
            try reconcileWithDisk()
        } else {
            try plan(size: probe.size, acceptsRanges: probe.acceptsRanges, validator: probe.validator)
        }
    }

    /// A one-byte ranged GET: unlike HEAD, it shows what the server does with a real Range.
    private func probeRemote() async throws -> (size: Int64?, acceptsRanges: Bool, validator: String?) {
        var failures = 0
        while true {
            do {
                let info = try await engine.transport.fetch(FetchRequest(url: url, headers: headers, range: 0..<1)).info
                switch info.statusCode {
                case 206:
                    guard let range = info.contentRange, range.start == 0, !info.isEncoded else {
                        return (nil, false, info.validator)
                    }
                    return (range.total, range.total != nil, info.validator)
                case 200..<300:
                    return (info.isEncoded ? nil : info.contentLength, false, info.validator)
                case 416:
                    return (nil, false, nil) // typically an empty resource
                default:
                    throw DownloadError.httpStatus(info.statusCode)
                }
            } catch {
                try await backoff(after: error, failures: &failures)
            }
        }
    }

    private func plan(size: Int64?, acceptsRanges: Bool, validator: String?) throws {
        engine.store.remove(id: id)
        let segmented = acceptsRanges && size != nil
        var segments: [Segment] = []
        if segmented, let size, size > 0 {
            let affordable = max(1, size / engine.configuration.minimumSegmentSize)
            let count = min(Int64(engine.configuration.concurrency), affordable)
            segments = (0..<count).map { index in
                Segment(id: Int(index), start: size * index / count, end: size * (index + 1) / count)
            }
        } else if !segmented {
            segments = [Segment(id: 0, start: 0, end: size)]
        }
        state.size = size
        state.acceptsRanges = segmented
        state.validator = validator
        state.segments = segments
        hasPlan = true
        try engine.store.save(state)
        for segment in segments { try createPart(segment.id) }
    }

    private func reconcileWithDisk() throws {
        try engine.store.prepareDirectory(for: id)
        for index in state.segments.indices {
            let segment = state.segments[index]
            let part = engine.store.partURL(id: id, segment: segment.id)
            let onDisk = ((try? FileManager.default.attributesOfItem(atPath: part.path))?[.size] as? NSNumber)?.int64Value
            guard let onDisk else {
                state.segments[index].written = 0
                try createPart(segment.id)
                continue
            }
            let usable = min(onDisk, max(0, (segment.end ?? 0) - segment.start))
            state.segments[index].written = usable
            if usable < onDisk { try truncate(part, to: usable) }
        }
        try engine.store.save(state)
    }

    private func createPart(_ segment: Int) throws {
        let path = engine.store.partURL(id: id, segment: segment).path
        guard FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw DownloadError.io("cannot create part \(segment)")
        }
    }

    private func truncate(_ part: URL, to length: Int64) throws {
        do {
            let handle = try FileHandle(forWritingTo: part)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(length))
        } catch {
            throw DownloadError.io(error.localizedDescription)
        }
    }

    // MARK: Scheduling

    private func downloadSegments() async throws {
        setPhase(.downloading)
        samples = []
        let limit = engine.configuration.concurrency
        try await withThrowingTaskGroup(of: Void.self) { group in
            var running = 0
            while true {
                while running < limit, let segment = try nextSegment() {
                    active.insert(segment.id)
                    running += 1
                    group.addTask {
                        do {
                            try await self.runSegment(segment)
                            await self.segmentStopped(segment.id)
                        } catch {
                            await self.segmentStopped(segment.id)
                            throw error
                        }
                    }
                }
                guard running > 0 else { return }
                _ = try await group.next()
                running -= 1
            }
        }
    }

    private func nextSegment() throws -> Segment? {
        if let waiting = state.segments.first(where: { !$0.isComplete && !active.contains($0.id) }) {
            return waiting
        }
        return try splitLargestSegment()
    }

    /// When a connection falls idle, the running segment with the most left gives away its
    /// back half, so slow connections shed work without any timing heuristics. A stalled
    /// connection is ended by the transport's timeout and retried. A worker can already be
    /// past the moved end by the time it notices; chain selection discards that excess.
    private func splitLargestSegment() throws -> Segment? {
        guard state.acceptsRanges else { return nil }
        let candidates = state.segments.indices.filter { active.contains(state.segments[$0].id) }
        guard let index = candidates.max(by: { (state.segments[$0].remaining ?? 0) < (state.segments[$1].remaining ?? 0) }),
              let remaining = state.segments[index].remaining, let end = state.segments[index].end,
              remaining >= 2 * engine.configuration.minimumSegmentSize else { return nil }
        let middle = end - remaining / 2
        let tail = Segment(id: (state.segments.map(\.id).max() ?? 0) + 1, start: middle, end: end)
        state.segments[index].end = middle
        state.segments.append(tail)
        try createPart(tail.id)
        try engine.store.save(state)
        return tail
    }

    // MARK: Worker

    private nonisolated func runSegment(_ initial: Segment) async throws {
        let part = engine.store.partURL(id: id, segment: initial.id)
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: part)
            try handle.seek(toOffset: UInt64(initial.written))
        } catch {
            throw DownloadError.io(error.localizedDescription)
        }
        defer { try? handle.close() }

        var offset = initial.written
        var failures = 0
        while true {
            let before = offset
            do {
                try Task.checkCancellation()
                try await transfer(segmentID: initial.id, to: handle, offset: &offset)
                return
            } catch {
                // Without ranges a new attempt restarts at zero, so its bytes are not progress:
                // counting them would let a body that always ends short retry forever.
                let restarts = await restartsFromZero()
                if offset > before, !restarts { failures = 0 }
                try await backoff(after: error, failures: &failures)
                if restarts {
                    offset = 0
                    do {
                        try handle.truncate(atOffset: 0)
                        try handle.seek(toOffset: 0)
                    } catch {
                        throw DownloadError.io(error.localizedDescription)
                    }
                    await record(initial.id, written: 0)
                }
            }
        }
    }

    private func restartsFromZero() -> Bool { !state.acceptsRanges }

    private nonisolated func transfer(segmentID: Int, to handle: FileHandle, offset: inout Int64) async throws {
        let (segment, ranged, size, validator) = await workerView(segmentID)
        var range: Range<Int64>?
        if ranged, let end = segment.end {
            let from = segment.start + offset
            guard from < end else { return }
            range = from..<end
        }
        let response = try await engine.transport.fetch(FetchRequest(url: url, headers: headers, range: range))
        try check(response.info, range: range, size: size, validator: validator)
        if !ranged, size == nil, !response.info.isEncoded, let length = response.info.contentLength {
            await adoptLength(length, segmentID: segmentID)
        }
        for try await chunk in response.body {
            var data = chunk
            let budget = await remaining(segmentID, offset: offset)
            if let budget {
                if !ranged, Int64(data.count) > budget {
                    throw DownloadError.sizeMismatch(expected: offset + budget, actual: offset + Int64(data.count))
                }
                data = data.prefix(Int(min(budget, Int64(data.count))))
            }
            do {
                try handle.write(contentsOf: data)
            } catch {
                throw DownloadError.io(error.localizedDescription)
            }
            offset += Int64(data.count)
            await record(segmentID, written: offset)
            if let budget, budget <= Int64(data.count) { return }
        }
        // An AsyncThrowingStream ends quietly on cancellation, which is not an EOF.
        try Task.checkCancellation()
        if let left = await remaining(segmentID, offset: offset), left > 0 {
            throw ShortBody(expected: offset + left, actual: offset)
        }
        if await sizeIsUnknown() { await adoptLength(offset, segmentID: segmentID) }
    }

    private nonisolated func check(_ info: HTTPResponseInfo, range: Range<Int64>?, size: Int64?, validator: String?) throws {
        if let range {
            if (200..<300).contains(info.statusCode), info.statusCode != 206 { throw DownloadError.rangeNotHonored }
            guard info.statusCode == 206 else { throw DownloadError.httpStatus(info.statusCode) }
            guard let contentRange = info.contentRange, contentRange.start == range.lowerBound,
                  contentRange.total == nil || contentRange.total == size, !info.isEncoded else {
                throw DownloadError.rangeNotHonored
            }
        } else if !(200..<300).contains(info.statusCode) {
            throw DownloadError.httpStatus(info.statusCode)
        }
        if let validator, let current = info.validator, current != validator {
            throw DownloadError.remoteChanged
        }
    }

    /// Rethrows anything fatal, otherwise waits out the next retry delay.
    private nonisolated func backoff(after error: Error, failures: inout Int) async throws {
        if error is CancellationError { throw error }
        if let error = error as? DownloadError {
            guard case .httpStatus(let code) = error, code == 408 || code == 425 || code == 429 || code >= 500 else { throw error }
        }
        failures += 1
        let configuration = engine.configuration
        guard failures <= configuration.maxRetries else {
            if let short = error as? ShortBody {
                throw DownloadError.sizeMismatch(expected: short.expected, actual: short.actual)
            }
            throw DownloadError.retriesExhausted(attempts: failures, lastError: error.localizedDescription)
        }
        let scale = 1 << min(failures - 1, 20)
        try await engine.sleep(min(configuration.baseRetryDelay * scale, configuration.maxRetryDelay))
    }

    // MARK: Worker bookkeeping

    private func workerView(_ id: Int) -> (Segment, Bool, Int64?, String?) {
        (state.segments.first { $0.id == id } ?? Segment(id: id, start: 0, end: 0), state.acceptsRanges, state.size, state.validator)
    }

    private func remaining(_ id: Int, offset: Int64) -> Int64? {
        guard let segment = state.segments.first(where: { $0.id == id }), let end = segment.end else { return nil }
        return max(0, end - segment.start - offset)
    }

    private func sizeIsUnknown() -> Bool { state.size == nil }

    private func adoptLength(_ length: Int64, segmentID: Int) {
        state.size = length
        if let index = state.segments.firstIndex(where: { $0.id == segmentID }) {
            state.segments[index].end = length
        }
    }

    private func record(_ id: Int, written: Int64) {
        if let index = state.segments.firstIndex(where: { $0.id == id }) {
            state.segments[index].written = written
        }
        emitIfDue()
    }

    private func segmentStopped(_ id: Int) {
        active.remove(id)
    }

    // MARK: Progress

    private func setPhase(_ next: DownloadPhase) {
        phase = next
        continuation.yield(snapshot())
    }

    private func emitIfDue() {
        let now = engine.clock()
        guard now - lastEmit >= engine.configuration.progressInterval else { return }
        lastEmit = now
        continuation.yield(snapshot())
    }

    private func snapshot() -> DownloadProgress {
        let received = state.segments.reduce(Int64(0)) { $0 + $1.covered }
        let now = engine.clock()
        samples.append((now, received))
        samples.removeAll { now - $0.time > engine.configuration.speedWindow }
        var speed = 0.0
        if let first = samples.first, now > first.time {
            speed = Double(max(0, received - first.bytes)) / (now - first.time)
        }
        return DownloadProgress(
            id: id, phase: phase, receivedBytes: received, totalBytes: state.size,
            bytesPerSecond: speed, activeSegments: active.count
        )
    }
}
