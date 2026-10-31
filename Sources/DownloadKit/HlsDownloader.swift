import Foundation

/// Origin and header policy for every playlist, redirect, map and segment request.
public enum HlsRequestPolicy {
    private static let sensitiveHeaders: Set<String> = ["authorization", "cookie", "origin", "proxy-authorization", "referer"]

    public static func initialURL(_ text: String) -> URL? {
        URL(string: text).flatMap(httpsOnly)
    }

    public static func resolve(base: URL, candidate: String) -> URL? {
        URL(string: candidate, relativeTo: base)?.absoluteURL.standardized.nonEmptyHost.flatMap(httpsOnly)
    }

    public static func headers(for target: URL, credentialOrigin: URL, headers: [String: String]) -> [String: String] {
        if sameOrigin(target, credentialOrigin) { return headers }
        return headers.filter { !sensitiveHeaders.contains($0.key.lowercased()) }
    }

    public static func sameOrigin(_ left: URL, _ right: URL) -> Bool {
        left.scheme?.lowercased() == right.scheme?.lowercased()
            && left.host?.lowercased() == right.host?.lowercased()
            && effectivePort(left) == effectivePort(right)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : nil)
    }

    private static func httpsOnly(_ url: URL) -> URL? {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false ? url : nil
    }
}

private extension URL {
    var nonEmptyHost: URL? { host?.isEmpty == false ? self : nil }
}

public enum HlsError: Error, Sendable, Equatable, LocalizedError {
    case insecureURL
    case httpStatus(Int)
    case tooManyRedirects
    case unsupportedPlaylist
    case emptyPlaylist
    case limitExceeded(String)
    case emptySegment

    public var errorDescription: String? {
        switch self {
        case .insecureURL: return "hls requires https urls"
        case .httpStatus(let code): return "hls request returned http \(code)"
        case .tooManyRedirects: return "hls request redirected too many times"
        case .unsupportedPlaylist: return "hls playlist uses encryption or byte ranges"
        case .emptyPlaylist: return "hls playlist has no segments"
        case .limitExceeded(let what): return "hls limit exceeded: \(what)"
        case .emptySegment: return "hls segment was empty"
        }
    }
}

/// Bounded HLS downloader that never forwards credentials across origins. Redirects are
/// followed here, so each hop gets its headers from `HlsRequestPolicy`.
public struct HlsDownloader: Sendable {
    public static let maxRedirects = 5
    public static let maxPlaylistBytes: Int64 = 1 << 20
    public static let maxSegments = 20_000
    public static let maxSegmentBytes: Int64 = 512 << 20
    public static let maxTotalBytes: Int64 = 100 << 30

    let transport: any DownloadTransport
    let maxSegmentSize: Int64
    let maxTotalSize: Int64

    public init(transport: any DownloadTransport = URLSessionTransport()) {
        self.init(transport: transport, maxSegmentSize: Self.maxSegmentBytes, maxTotalSize: Self.maxTotalBytes)
    }

    init(transport: any DownloadTransport, maxSegmentSize: Int64, maxTotalSize: Int64) {
        self.transport = transport
        self.maxSegmentSize = maxSegmentSize
        self.maxTotalSize = maxTotalSize
    }

    /// Writes the init map and segments, in order, to a temp file beside `destination`, then
    /// publishes under a free name, so an existing file is never touched. Returns where it landed.
    @discardableResult
    public func download(
        url: String, headers: [String: String] = [:], destination: URL,
        onBytes: @escaping @Sendable (Int64) async -> Void = { _ in }
    ) async throws -> URL {
        guard let origin = HlsRequestPolicy.initialURL(url) else { throw HlsError.insecureURL }
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).download")
        defer { try? FileManager.default.removeItem(at: temp) }
        let master = try await fetchText(origin, origin: origin, headers: headers)
        let mediaURL = try Self.resolveMediaPlaylist(base: master.finalURL, text: master.text)
        let media = mediaURL == master.finalURL ? master : try await fetchText(mediaURL, origin: origin, headers: headers)
        if media.text.contains("#EXT-X-KEY") || media.text.contains("#EXT-X-BYTERANGE") {
            throw HlsError.unsupportedPlaylist
        }
        var targets: [URL] = []
        if let map = Self.parseMapURI(media.text) {
            // As in YunX, a map that cannot be resolved is left out; the segments still play.
            if let resolved = HlsRequestPolicy.resolve(base: media.finalURL, candidate: map) { targets.append(resolved) }
        }
        let segments = try Self.parseSegments(media.text)
        guard !segments.isEmpty else { throw HlsError.emptyPlaylist }
        for segment in segments {
            guard let resolved = HlsRequestPolicy.resolve(base: media.finalURL, candidate: segment) else {
                throw HlsError.insecureURL
            }
            targets.append(resolved)
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: temp.path, contents: nil) else {
            throw DownloadError.io("cannot create \(destination.lastPathComponent)")
        }
        let output = try FileHandle(forWritingTo: temp)
        defer { try? output.close() }
        var total: Int64 = 0
        for target in targets {
            let wrote = try await fetch(target, origin: origin, headers: headers, output: output, total: &total, onBytes: onBytes)
            if wrote <= 0 { throw HlsError.emptySegment }
        }
        try output.synchronize()
        return try DownloadFinalizer.publish(temp, to: destination)
    }

    struct FetchedText {
        var finalURL: URL
        var text: String
    }

    private func follow(_ start: URL, origin: URL, headers: [String: String]) async throws -> (URL, FetchResponse) {
        var current = start
        for _ in 0...Self.maxRedirects {
            let request = FetchRequest(
                url: current, headers: HlsRequestPolicy.headers(for: current, credentialOrigin: origin, headers: headers),
                followRedirects: false
            )
            let response = try await transport.fetch(request)
            if (300...399).contains(response.info.statusCode), let location = response.info.headers["location"] {
                guard let next = HlsRequestPolicy.resolve(base: current, candidate: location) else { throw HlsError.insecureURL }
                current = next
                continue
            }
            guard (200..<300).contains(response.info.statusCode) else { throw HlsError.httpStatus(response.info.statusCode) }
            return (current, response)
        }
        throw HlsError.tooManyRedirects
    }

    func fetchText(_ start: URL, origin: URL, headers: [String: String]) async throws -> FetchedText {
        let (finalURL, response) = try await follow(start, origin: origin, headers: headers)
        if let length = response.info.contentLength, length > Self.maxPlaylistBytes {
            throw HlsError.limitExceeded("playlist size")
        }
        var data = Data()
        for try await chunk in response.body {
            data.append(chunk)
            if Int64(data.count) > Self.maxPlaylistBytes { throw HlsError.limitExceeded("playlist size") }
        }
        try Task.checkCancellation()
        return FetchedText(finalURL: finalURL, text: String(decoding: data, as: UTF8.self))
    }

    private func fetch(
        _ start: URL, origin: URL, headers: [String: String], output: FileHandle, total: inout Int64,
        onBytes: @Sendable (Int64) async -> Void
    ) async throws -> Int64 {
        let (_, response) = try await follow(start, origin: origin, headers: headers)
        if let length = response.info.contentLength, length > maxSegmentSize { throw HlsError.limitExceeded("segment size") }
        var written: Int64 = 0
        for try await chunk in response.body {
            written += Int64(chunk.count)
            if written > maxSegmentSize { throw HlsError.limitExceeded("segment size") }
            total += Int64(chunk.count)
            if total > maxTotalSize { throw HlsError.limitExceeded("total size") }
            try output.write(contentsOf: chunk)
            await onBytes(Int64(chunk.count))
        }
        try Task.checkCancellation()
        return written
    }

    private static func lines(_ text: String) -> [Substring] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    }

    /// The first variant of a master playlist, else the playlist itself.
    static func resolveMediaPlaylist(base: URL, text: String) throws -> URL {
        let lines = lines(text)
        for index in lines.indices where lines[index].hasPrefix("#EXT-X-STREAM-INF") && index + 1 < lines.count {
            let next = lines[index + 1].trimmingCharacters(in: .whitespaces)
            if !next.isEmpty, !next.hasPrefix("#") {
                guard let url = HlsRequestPolicy.resolve(base: base, candidate: next) else { throw HlsError.insecureURL }
                return url
            }
        }
        return base
    }

    static func parseSegments(_ text: String) throws -> [String] {
        var segments: [String] = []
        for line in lines(text) {
            let value = line.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, !value.hasPrefix("#") else { continue }
            if segments.count >= maxSegments { throw HlsError.limitExceeded("segment count") }
            segments.append(value)
        }
        return segments
    }

    static func parseMapURI(_ text: String) -> String? {
        guard let line = lines(text).first(where: { $0.hasPrefix("#EXT-X-MAP") }),
              let found = line.range(of: "URI=\"[^\"]+\"", options: .regularExpression) else { return nil }
        return String(line[found].dropFirst(5).dropLast())
    }
}
