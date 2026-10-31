import Foundation

public struct Segment: Codable, Sendable, Equatable {
    public var id: Int
    public var start: Int64
    /// Exclusive end; nil while the resource size is unknown.
    public var end: Int64?
    public var written: Int64
    /// SHA-256 of the finished part; a part without one is still in progress.
    public var sha256: String?

    public init(id: Int, start: Int64, end: Int64?, written: Int64 = 0, sha256: String? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.written = written
        self.sha256 = sha256
    }

    /// Bytes this segment still owes, or nil when its end is unknown.
    var remaining: Int64? { end.map { max(0, $0 - start - written) } }
    var isComplete: Bool { remaining == 0 }
    /// Useful bytes: `written` is clamped because a re-split can move the end.
    var covered: Int64 { end.map { min(written, max(0, $0 - start)) } ?? written }
}

/// One piece of the merged output: `length` bytes of the segment's part file, after `skip`.
public struct ChainLink: Sendable, Equatable {
    public var segmentID: Int
    public var skip: Int64
    public var length: Int64
}

public enum SegmentChain {
    /// Picks a contiguous, non-overlapping chain covering `0..<size`. At each cursor it takes
    /// the segment holding that byte which reaches furthest, skipping any overlapping prefix.
    public static func select(segments: [Segment], size: Int64) -> Result<[ChainLink], DownloadError> {
        var chain: [ChainLink] = []
        var cursor: Int64 = 0
        while cursor < size {
            var best: (segment: Segment, reach: Int64)?
            for segment in segments where segment.start <= cursor {
                let reach = min(segment.start + segment.covered, size)
                if reach > (best?.reach ?? cursor) {
                    best = (segment, reach)
                }
            }
            guard let best else {
                let next = segments.compactMap { $0.covered > 0 && $0.start > cursor ? $0.start : nil }.min()
                return .failure(.incompleteData(gap: cursor..<min(next ?? size, size)))
            }
            chain.append(ChainLink(segmentID: best.segment.id, skip: cursor - best.segment.start, length: best.reach - cursor))
            cursor = best.reach
        }
        return .success(chain)
    }
}
