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
    /// Paces the slow-connection watchdog, apart from `sleep` so it never counts as a retry delay.
    let watchdogSleep: Sleep

    public init(
        configuration: DownloadConfiguration = DownloadConfiguration(),
        transport: any DownloadTransport = URLSessionTransport(),
        store: DownloadStore,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        clock: @escaping Clock = { ProcessInfo.processInfo.systemUptime },
        watchdogSleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.configuration = configuration
        self.transport = transport
        self.store = store
        self.sleep = sleep
        self.clock = clock
        self.watchdogSleep = watchdogSleep
    }

    /// Uses `Application Support/Thermo/Downloads`.
    public init(configuration: DownloadConfiguration = DownloadConfiguration()) throws {
        self.init(configuration: configuration, store: DownloadStore(root: try DownloadStore.defaultRoot()))
    }

    public func makeTask(_ request: DownloadRequest) throws -> DownloadTask {
        try Self.checkLink(request.url)
        let state = DownloadState(
            id: UUID(), url: request.url, destination: request.destination,
            size: nil, acceptsRanges: false, validator: nil, segments: []
        )
        return DownloadTask(
            engine: self, state: state, link: request.url, needsNewLink: false, isRestored: false,
            headers: try Self.requestHeaders(request.headers, request.cookies), refreshLink: request.refreshLink
        )
    }

    /// Rebuilds a task from its state file. Credentials and URL queries were never saved, so
    /// pass them again: give `url` for a link with a query, or `refreshLink` to fetch a new one.
    public func restore(
        id: UUID, url: URL? = nil, headers: [String: String] = [:], cookies: [DownloadCookie] = [],
        refreshLink: LinkRefresher? = nil
    ) throws -> DownloadTask {
        let state = try store.load(id: id)
        if let url { try Self.checkLink(url) }
        let needsNewLink = url == nil && state.linkIsRedacted == true
        if needsNewLink, refreshLink == nil { throw DownloadError.linkRequired }
        return DownloadTask(
            engine: self, state: state, link: url ?? state.url, needsNewLink: needsNewLink, isRestored: true,
            headers: try Self.requestHeaders(headers, cookies), refreshLink: refreshLink
        )
    }

    public func savedDownloads() -> [DownloadState] {
        store.list()
    }

    static func checkLink(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw DownloadError.unsupportedURL("only http and https are supported")
        }
        guard url.user == nil, url.password == nil else {
            throw DownloadError.unsupportedURL("credentials in the url; pass them as headers")
        }
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

/// Sampling for one running segment; survives reconnects so the limits apply per segment.
private struct InflightSegment {
    let startedAt: TimeInterval
    var bytes: Int64
    var lastAt: TimeInterval
    var lastActivity: TimeInterval
    var lastRate: Int64 = 0
    var preemptions = 0
    var lastPreemptAt: TimeInterval = -.infinity

    init(startedAt: TimeInterval, bytes: Int64) {
        self.startedAt = startedAt
        self.bytes = bytes
        self.lastAt = startedAt
        self.lastActivity = startedAt
    }
}

/// Lets a connection task write to the part. Only one connection per segment runs at a time.
private struct PartOutput: @unchecked Sendable {
    let handle: FileHandle
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
    private nonisolated let refreshLink: LinkRefresher?
    /// The live link. May carry a signed query, so it stays out of `state`.
    private var url: URL
    private var headers: [String: String]
    private var linkGeneration = 0
    private var needsNewLink: Bool
    private var refreshTask: Task<Void, Error>?
    private var refreshesSinceProgress = 0
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
    private var inflight: [Int: InflightSegment] = [:]
    private var connections: [Int: Task<Void, Error>] = [:]
    private var preempting = Set<Int>()
    private var runStartedAt: TimeInterval = 0
    private var runStartBytes: Int64 = 0

    init(
        engine: DownloadEngine, state: DownloadState, link: URL, needsNewLink: Bool, isRestored: Bool,
        headers: [String: String], refreshLink: LinkRefresher?
    ) {
        self.engine = engine
        self.state = state
        self.hasPlan = isRestored
        self.url = link
        self.needsNewLink = needsNewLink
        self.headers = headers
        self.refreshLink = refreshLink
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
            var repairs = 0
            var finished: URL
            while true {
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
                do {
                    finished = try await merge()
                    break
                } catch DownloadError.corruptPart(let segment) where repairs < 2 {
                    // Parts are only read by a merge, so everything else is still good.
                    repairs += 1
                    try resetSegment(segment)
                }
            }
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
        // Every byte is already on disk and hashed: verify the parts and merge without the network,
        // so an expired or unrefreshable link cannot strand a finished download.
        if hasPlan, state.size != nil, !state.segments.isEmpty,
           state.segments.allSatisfy({ $0.isComplete && $0.sha256 != nil }) {
            try reconcileWithDisk()
            if state.segments.allSatisfy(\.isComplete) { return }
        }
        if needsNewLink {
            try await refreshedLink(seen: linkGeneration, statusCode: nil, cause: .linkRequired)
            needsNewLink = false
        }
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
            let generation = linkGeneration
            do {
                let info = try await engine.transport.fetch(FetchRequest(url: url, headers: headers, range: 0..<1)).info
                if Self.looksLikeErrorPage(info) { throw DownloadError.htmlResponse }
                switch info.statusCode {
                case 206:
                    guard let range = info.contentRange, range.start == 0, range.end == 0, !info.isEncoded else {
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
                if let expiry = Self.expiry(of: error), refreshLink != nil {
                    try await refreshedLink(seen: generation, statusCode: expiry.statusCode, cause: expiry.cause)
                } else {
                    try await backoff(after: error, failures: &failures)
                }
            }
        }
    }

    /// YunX reads an HTML reply as an anti-hotlink or expiry page and refuses to save it.
    /// Server errors keep their status so they stay retryable.
    private nonisolated static func looksLikeErrorPage(_ info: HTTPResponseInfo) -> Bool {
        info.isHTML && info.statusCode < 500 && info.statusCode != 429
    }

    /// 403/404 are what YunX treats as a dead link; 401 and 410 mean the same for signed URLs.
    private nonisolated static func expiry(of error: Error) -> (statusCode: Int?, cause: DownloadError)? {
        switch error as? DownloadError {
        case .httpStatus(let code) where [401, 403, 404, 410].contains(code):
            return (code, .linkExpired)
        case .htmlResponse:
            return (nil, .linkExpired)
        default:
            return nil
        }
    }

    // MARK: Link refresh

    private func currentLink() -> (url: URL, headers: [String: String], generation: Int) {
        (url, headers, linkGeneration)
    }

    /// Single flight: workers that hit the same dead link share one refresh, and one that
    /// failed on an older link just picks up the newer one.
    private func refreshedLink(seen: Int, statusCode: Int?, cause: DownloadError) async throws {
        if linkGeneration > seen { return }
        let task: Task<Void, Error>
        if let refreshTask {
            task = refreshTask
        } else {
            guard let refreshLink else { throw cause }
            guard refreshesSinceProgress < engine.configuration.maxLinkRefreshes else { throw cause }
            refreshesSinceProgress += 1
            let expiry = LinkExpiry(taskID: id, url: state.url, statusCode: statusCode)
            task = Task {
                do {
                    guard let fresh = try await refreshLink(expiry) else { throw cause }
                    try DownloadEngine.checkLink(fresh.url)
                    let freshHeaders = try fresh.headers.map { try DownloadEngine.requestHeaders($0, []) }
                    self.adoptLink(fresh.url, headers: freshHeaders)
                } catch {
                    self.refreshFailed()
                    throw error
                }
            }
            refreshTask = task
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func adoptLink(_ link: URL, headers fresh: [String: String]?) {
        url = link
        if let fresh { headers = fresh }
        linkGeneration += 1
        refreshTask = nil
    }

    private func refreshFailed() {
        refreshTask = nil
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
            let length = max(0, (segment.end ?? 0) - segment.start)
            if let hash = segment.sha256 {
                // Finished parts must prove themselves; the rest resume from their length.
                if onDisk < length || (try? PartHash.hash(of: part, length: length)) != hash {
                    try resetPart(index, part)
                } else {
                    state.segments[index].written = length
                    if onDisk > length { try truncate(part, to: length) }
                }
                continue
            }
            if onDisk >= length, length > 0 {
                // Fully written but never recorded: a crash beat the hash, so nothing vouches for it.
                try resetPart(index, part)
                continue
            }
            state.segments[index].written = onDisk
        }
        try engine.store.save(state)
    }

    private func resetPart(_ index: Int, _ part: URL) throws {
        try truncate(part, to: 0)
        state.segments[index].written = 0
        state.segments[index].sha256 = nil
    }

    private func resetSegment(_ id: Int) throws {
        guard let index = state.segments.firstIndex(where: { $0.id == id }) else { return }
        try resetPart(index, engine.store.partURL(id: self.id, segment: id))
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
        runStartedAt = engine.clock()
        runStartBytes = state.segments.reduce(0) { $0 + $1.covered }
        let watchdog = startWatchdog()
        defer { watchdog?.cancel() }
        let limit = engine.configuration.concurrency
        try await withThrowingTaskGroup(of: Void.self) { group in
            var running = 0
            while true {
                while running < limit, let segment = try nextSegment() {
                    active.insert(segment.id)
                    inflight[segment.id] = InflightSegment(startedAt: engine.clock(), bytes: segment.written)
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
        let output = PartOutput(handle: handle)

        var offset = initial.written
        var failures = 0
        while true {
            let before = offset
            let link = await currentLink()
            do {
                try Task.checkCancellation()
                try await connect(segmentID: initial.id, output: output, offset: offset, link: link)
                try await sealSegment(initial.id, handle: handle, part: part)
                return
            } catch {
                offset = await writtenBytes(initial.id)
                if Task.isCancelled { throw CancellationError() }
                if await takePreemption(initial.id) { continue } // a new connection, not a failure
                // Without ranges a new attempt restarts at zero, so its bytes are not progress:
                // counting them would let a body that always ends short retry forever.
                let restarts = await restartsFromZero()
                if offset > before, !restarts { failures = 0 }
                if let expiry = Self.expiry(of: error), refreshLink != nil {
                    try await refreshedLink(seen: link.generation, statusCode: expiry.statusCode, cause: expiry.cause)
                } else {
                    try await backoff(after: error, failures: &failures)
                }
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

    /// One connection in a task of its own: cancelling it wakes a read the server is holding
    /// open, which a flag checked between chunks could not do.
    private nonisolated func connect(
        segmentID: Int, output: PartOutput, offset: Int64, link: (url: URL, headers: [String: String], generation: Int)
    ) async throws {
        let connection = Task {
            try await self.transfer(segmentID: segmentID, output: output, offset: offset, link: link)
        }
        await registerConnection(segmentID, connection)
        let result = await withTaskCancellationHandler {
            await connection.result
        } onCancel: {
            connection.cancel()
        }
        await unregisterConnection(segmentID)
        try result.get()
    }

    /// Flushes before recording, so a hash on disk always describes bytes on disk.
    private nonisolated func sealSegment(_ id: Int, handle: FileHandle, part: URL) async throws {
        guard let length = await sealableLength(id) else { return }
        do {
            try handle.synchronize()
            await recordHash(id, try PartHash.hash(of: part, length: length))
        } catch {
            throw DownloadError.io(error.localizedDescription)
        }
    }

    private func restartsFromZero() -> Bool { !state.acceptsRanges }

    private func writtenBytes(_ id: Int) -> Int64 {
        state.segments.first { $0.id == id }?.written ?? 0
    }

    private func sealableLength(_ id: Int) -> Int64? {
        guard state.acceptsRanges, let segment = state.segments.first(where: { $0.id == id }), segment.isComplete else {
            return nil
        }
        return segment.covered
    }

    private func recordHash(_ id: Int, _ hash: String) {
        guard let index = state.segments.firstIndex(where: { $0.id == id }) else { return }
        state.segments[index].sha256 = hash
        try? engine.store.save(state)
    }

    private nonisolated func transfer(
        segmentID: Int, output: PartOutput, offset start: Int64, link: (url: URL, headers: [String: String], generation: Int)
    ) async throws {
        var offset = start
        let (segment, ranged, size, validator) = await workerView(segmentID)
        var range: Range<Int64>?
        if ranged, let end = segment.end {
            let from = segment.start + offset
            guard from < end else { return }
            range = from..<end
        }
        let response = try await engine.transport.fetch(FetchRequest(url: link.url, headers: link.headers, range: range))
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
                try output.handle.write(contentsOf: data)
            } catch {
                throw DownloadError.io(error.localizedDescription)
            }
            offset += Int64(data.count)
            await record(segmentID, written: offset, generation: link.generation)
            // Waiting here stops reading, which is what slows the server down.
            try await engine.configuration.speedLimiter?.acquire(Int64(data.count))
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
        if Self.looksLikeErrorPage(info) { throw DownloadError.htmlResponse }
        if let range {
            if (200..<300).contains(info.statusCode), info.statusCode != 206 { throw DownloadError.rangeNotHonored }
            guard info.statusCode == 206 else { throw DownloadError.httpStatus(info.statusCode) }
            guard !info.isEncoded else { throw DownloadError.rangeNotHonored }
            let requested = (range.lowerBound, range.upperBound - 1)
            guard HTTPRangePolicy.matches(info.headers["content-range"], start: requested.0, end: requested.1) else {
                throw DownloadError.contentRangeMismatch
            }
            if let total = info.contentRange?.total, let size, total != size { throw DownloadError.remoteChanged }
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

    /// Only bytes on the current link vouch for it: an older connection can keep streaming
    /// after the link died, and must not reset the refresh limit.
    private func record(_ id: Int, written: Int64, generation: Int? = nil) {
        if let index = state.segments.firstIndex(where: { $0.id == id }) {
            state.segments[index].written = written
        }
        if written > 0, generation == linkGeneration { refreshesSinceProgress = 0 }
        inflight[id]?.lastActivity = engine.clock()
        emitIfDue()
    }

    private func segmentStopped(_ id: Int) {
        active.remove(id)
        inflight[id] = nil
        preempting.remove(id)
    }

    private func registerConnection(_ id: Int, _ connection: Task<Void, Error>) {
        connections[id] = connection
    }

    private func unregisterConnection(_ id: Int) {
        connections[id] = nil
    }

    private func takePreemption(_ id: Int) -> Bool {
        preempting.remove(id) != nil
    }

    // MARK: Slow connections

    private func startWatchdog() -> Task<Void, Never>? {
        let policy = engine.configuration.preemption
        guard policy.isEnabled, state.acceptsRanges else { return nil }
        return Task { [engine] in
            while !Task.isCancelled {
                do {
                    try await engine.watchdogSleep(.seconds(policy.tick))
                } catch {
                    return
                }
                self.preemptSlowSegments()
            }
        }
    }

    /// Replaces connections well behind their peers: CDNs cap per connection and the odd one
    /// lands on a bad node, which ruins the tail of a download. Keeps every written byte.
    func preemptSlowSegments() {
        let policy = engine.configuration.preemption
        let now = engine.clock()
        for id in Array(inflight.keys) {
            guard var sample = inflight[id] else { continue }
            let bytes = writtenBytes(id)
            let span = now - sample.lastAt
            if span > 0 { sample.lastRate = Int64(Double(bytes - sample.bytes) / span) }
            sample.bytes = bytes
            sample.lastAt = now
            inflight[id] = sample
        }
        guard policy.isEnabled, state.acceptsRanges, !inflight.isEmpty else { return }
        let received = state.segments.reduce(Int64(0)) { $0 + $1.covered } - runStartBytes
        let elapsed = now - runStartedAt
        let workers = Int64(engine.configuration.concurrency)
        let average = elapsed > 0 ? Int64(Double(received) / elapsed) / workers : 0
        let floor = policy.floorBytesPerSecond(averagePerConnection: average)
        let endgame = inflight.count <= policy.endgameInflight
        var taken = 0
        for (id, sample) in inflight.sorted(by: { $0.value.lastRate < $1.value.lastRate }) {
            guard taken < policy.maxPerTick else { break }
            guard let connection = connections[id], sample.preemptions < policy.maxPerSegment,
                  now - sample.lastPreemptAt >= policy.cooldown, sample.lastRate < floor else { continue }
            let age = now - sample.startedAt
            if endgame {
                guard age >= policy.endgameMinAge else { continue }
            } else {
                let left = state.segments.first { $0.id == id }?.remaining ?? 0
                guard age >= policy.minAge, left >= policy.minRemaining else { continue }
            }
            inflight[id]?.preemptions += 1
            inflight[id]?.lastPreemptAt = now
            preempting.insert(id)
            connection.cancel()
            taken += 1
        }
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
