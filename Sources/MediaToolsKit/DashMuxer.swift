import Foundation

public enum DashMuxError: Error, Equatable, Sendable {
    case inputMissing
    /// Not a fragmented MP4, or not the expected track type.
    case notFragmented
    case malformed(String)
    case unsupported(String)
}

/// Remuxes split fragmented MP4 audio and video (Bilibili DASH) into one plain MP4, without re-encoding.
///
/// Timing is rebuilt per sample from moof/trun/tfhd/trex, because Bilibili keeps durations in the
/// defaults. It differs from YunX in three places: tfhd's default size and flags are read in spec
/// order (0x10 size, 0x20 flags; YunX swaps them), a trun with no data offset continues after the
/// previous run, and the 16-byte large mdat header is included in chunk offsets. Input is untrusted,
/// so every read is bounds-checked.
public enum DashMuxer {
    private static let videoHandler = "vide"
    private static let audioHandler = "soun"
    private static let movieTimescale: Int64 = 1000
    /// Limits for hostile headers; a real moov or moof is far smaller.
    private static let maxMetadataBox: Int64 = 256 << 20
    private static let maxSamples = 50_000_000

    public static func mux(video: URL, audio: URL, out: URL, onProgress: (Float) -> Void = { _ in }) throws {
        guard FfmpegMuxer.hasContent(video), FfmpegMuxer.hasContent(audio) else { throw DashMuxError.inputMissing }
        onProgress(0)
        let videoTrack = try Track(file: video, handler: videoHandler)
        let audioTrack = try Track(file: audio, handler: audioHandler)
        guard !videoTrack.durations.isEmpty, !audioTrack.durations.isEmpty else { throw DashMuxError.malformed("no samples") }
        onProgress(0.3)
        let staging = out.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).part")
        defer { try? FileManager.default.removeItem(at: staging) }
        try Mp4Writer.write([videoTrack, audioTrack], to: staging)
        _ = try FileManager.default.replaceItemAt(out, withItemAt: staging)
        onProgress(1)
    }

    // MARK: Reading

    private struct Bytes {
        let raw: [UInt8]
        var count: Int { raw.count }

        func u8(_ i: Int) throws -> Int {
            guard i >= 0, i < raw.count else { throw DashMuxError.malformed("truncated box") }
            return Int(raw[i])
        }
        func u32(_ i: Int) throws -> Int64 {
            guard i >= 0, i <= raw.count - 4 else { throw DashMuxError.malformed("truncated box") }
            return Int64(raw[i]) << 24 | Int64(raw[i + 1]) << 16 | Int64(raw[i + 2]) << 8 | Int64(raw[i + 3])
        }
        func i32(_ i: Int) throws -> Int64 { Int64(Int32(truncatingIfNeeded: try u32(i))) }
        func u64(_ i: Int) throws -> UInt64 { UInt64(try u32(i)) << 32 | UInt64(try u32(i + 4)) }
        func i64(_ i: Int) throws -> Int64 { Int64(truncatingIfNeeded: try u64(i)) }
        func ascii(_ i: Int, _ length: Int) throws -> String {
            _ = try u8(i + length - 1)
            return String(decoding: raw[i..<(i + length)], as: UTF8.self)
        }
        func slice(_ start: Int, _ end: Int) throws -> [UInt8] {
            guard start >= 0, start <= end, end <= raw.count else { throw DashMuxError.malformed("truncated box") }
            return Array(raw[start..<end])
        }
    }

    private struct Box {
        let type: String
        let start: Int
        let body: Int
        let end: Int
    }

    private static func boxes(_ bytes: Bytes, _ start: Int, _ end: Int) throws -> [Box] {
        var result: [Box] = []
        var position = start
        while position + 8 <= end {
            var size = Int(try bytes.u32(position))
            var headerLength = 8
            if size == 1 {
                let large = try bytes.u64(position + 8)
                guard large <= UInt64(end - position) else { throw DashMuxError.malformed("box overruns parent") }
                size = Int(large)
                headerLength = 16
            } else if size == 0 {
                size = end - position
            }
            guard size >= headerLength, position + size <= end else { throw DashMuxError.malformed("box overruns parent") }
            result.append(Box(type: try bytes.ascii(position + 4, 4), start: position, body: position + headerLength, end: position + size))
            position += size
        }
        return result
    }

    private static func find(_ bytes: Bytes, _ parent: Box, _ type: String) throws -> Box? {
        try boxes(bytes, parent.body, parent.end).last { $0.type == type }
    }

    private static func require(_ bytes: Bytes, _ parent: Box, _ type: String) throws -> Box {
        guard let box = try find(bytes, parent, type) else { throw DashMuxError.malformed("missing \(type)") }
        return box
    }

    private final class Track {
        let handle: FileHandle
        let length: Int64
        var handler = ""
        var timescale: Int64 = 0
        var sourceMovieTimescale = DashMuxer.movieTimescale
        var stsd: [UInt8] = []
        var matrix: [UInt8] = []
        var width: Int64 = 0
        var height: Int64 = 0
        var language: UInt16 = 0x55C4
        var durations: [Int64] = []
        var offsets: [Int64] = []
        var sizes: [Int64] = []
        var ctsRuns: [(count: Int64, value: Int64)] = []
        var sync: [Int64] = []
        var edits: [(segment: Int64, mediaTime: Int64, rate: Int64)] = []
        private var trexDuration: Int64 = 0
        private var trexSize: Int64 = 0
        private var trexFlags: Int64 = 0

        var totalDuration: Int64 { durations.reduce(0, &+) }

        deinit { try? handle.close() }

        init(file: URL, handler expected: String) throws {
            handle = try FileHandle(forReadingFrom: file)
            length = Int64(try handle.seekToEnd())
            var moof: [(offset: Int64, size: Int64)] = []
            var moov: Bytes?
            for box in try topLevelBoxes() {
                if box.type == "moov" {
                    moov = try read(box.offset, box.size)
                } else if box.type == "moof" {
                    moof.append((box.offset, box.size))
                }
            }
            guard let moov, !moof.isEmpty else { throw DashMuxError.notFragmented }
            try readMoov(moov)
            guard handler == expected else { throw DashMuxError.notFragmented }
            for box in moof { try readMoof(try read(box.offset, box.size), start: box.offset) }
        }

        private func read(_ offset: Int64, _ size: Int64) throws -> Bytes {
            guard size <= DashMuxer.maxMetadataBox else { throw DashMuxError.unsupported("metadata box too large") }
            try handle.seek(toOffset: UInt64(offset))
            let data = try handle.read(upToCount: Int(size)) ?? Data()
            guard data.count == Int(size) else { throw DashMuxError.malformed("truncated file") }
            return Bytes(raw: Array(data))
        }

        private func topLevelBoxes() throws -> [(type: String, offset: Int64, size: Int64)] {
            var result: [(String, Int64, Int64)] = []
            var position: Int64 = 0
            while position + 8 <= length {
                try handle.seek(toOffset: UInt64(position))
                let head = Bytes(raw: Array(try handle.read(upToCount: 16) ?? Data()))
                var size = try head.u32(0)
                if size == 1 {
                    let large = try head.u64(8)
                    guard large >= 16, large <= UInt64(length - position) else { throw DashMuxError.malformed("box overruns file") }
                    size = Int64(large)
                } else if size == 0 {
                    size = length - position
                }
                guard size >= 8, size <= length - position else { throw DashMuxError.malformed("box overruns file") }
                result.append((try head.ascii(4, 4), position, size))
                position += size
            }
            return result
        }

        private func readMoov(_ moov: Bytes) throws {
            let root = Box(type: "moov", start: 0, body: 8, end: moov.count)
            let trak = try DashMuxer.require(moov, root, "trak")
            let tkhd = try DashMuxer.require(moov, trak, "tkhd")
            let mdia = try DashMuxer.require(moov, trak, "mdia")
            let mdhd = try DashMuxer.require(moov, mdia, "mdhd")
            let hdlr = try DashMuxer.require(moov, mdia, "hdlr")
            let minf = try DashMuxer.require(moov, mdia, "minf")
            let stbl = try DashMuxer.require(moov, minf, "stbl")
            let stsdBox = try DashMuxer.require(moov, stbl, "stsd")

            stsd = try moov.slice(stsdBox.start, stsdBox.end)
            handler = try moov.ascii(hdlr.body + 8, 4)

            let longTimes = try moov.u8(mdhd.body) == 1
            timescale = try moov.u32(mdhd.body + (longTimes ? 20 : 12))
            guard timescale > 0 else { throw DashMuxError.malformed("zero timescale") }
            let packed = try moov.u32(mdhd.body + (longTimes ? 32 : 20) - 2) & 0xFFFF
            language = UInt16(packed)

            let matrixOffset = tkhd.body + (try moov.u8(tkhd.body) == 1 ? 52 : 40)
            matrix = try moov.slice(matrixOffset, matrixOffset + 36)
            width = try moov.u32(matrixOffset + 36)
            height = try moov.u32(matrixOffset + 40)

            if let edts = try DashMuxer.find(moov, trak, "edts"), let elst = try DashMuxer.find(moov, edts, "elst") {
                let long = try moov.u8(elst.body) == 1
                let count = try moov.u32(elst.body + 4)
                var i = elst.body + 8
                guard count <= Int64((elst.end - i) / (long ? 20 : 12)) else { throw DashMuxError.malformed("bad elst") }
                for _ in 0..<count {
                    let segment = long ? try moov.i64(i) : try moov.u32(i)
                    i += long ? 8 : 4
                    let mediaTime = long ? try moov.i64(i) : try moov.i32(i)
                    i += long ? 8 : 4
                    edits.append((segment, mediaTime, try moov.i32(i)))
                    i += 4
                }
            }

            if let mvhd = try DashMuxer.find(moov, root, "mvhd") {
                sourceMovieTimescale = try moov.u32(mvhd.body + (try moov.u8(mvhd.body) == 1 ? 20 : 12))
            }
            if let mvex = try DashMuxer.find(moov, root, "mvex"), let trex = try DashMuxer.find(moov, mvex, "trex") {
                trexDuration = try moov.u32(trex.body + 12)
                trexSize = try moov.u32(trex.body + 16)
                trexFlags = try moov.u32(trex.body + 20)
            }
        }

        private func readMoof(_ moof: Bytes, start: Int64) throws {
            let root = Box(type: "moof", start: 0, body: 8, end: moof.count)
            for traf in try DashMuxer.boxes(moof, root.body, root.end) where traf.type == "traf" {
                var base = start
                var defaultDuration = trexDuration
                var defaultSize = trexSize
                var defaultFlags = trexFlags
                let children = try DashMuxer.boxes(moof, traf.body, traf.end)
                if let tfhd = children.last(where: { $0.type == "tfhd" }) {
                    let flags = try moof.u32(tfhd.body) & 0xFFFFFF
                    var i = tfhd.body + 8
                    if flags & 0x01 != 0 { base = try moof.i64(i); i += 8 }
                    if flags & 0x02 != 0 { i += 4 }
                    if flags & 0x08 != 0 { defaultDuration = try moof.u32(i); i += 4 }
                    if flags & 0x10 != 0 { defaultSize = try moof.u32(i); i += 4 }
                    if flags & 0x20 != 0 { defaultFlags = try moof.u32(i); i += 4 }
                }
                var next = base
                for trun in children where trun.type == "trun" {
                    next = try readTrun(moof, trun, base: base, next: next, defaultDuration, defaultSize, defaultFlags)
                }
            }
        }

        private func readTrun(_ moof: Bytes, _ box: Box, base: Int64, next: Int64, _ defaultDuration: Int64, _ defaultSize: Int64, _ defaultFlags: Int64) throws -> Int64 {
            let b = box.body
            let version = try moof.u8(b)
            let flags = try moof.u32(b) & 0xFFFFFF
            let count = try moof.u32(b + 4)
            guard durations.count + Int(count) <= DashMuxer.maxSamples else { throw DashMuxError.unsupported("too many samples") }
            var i = b + 8
            var position = next
            if flags & 0x01 != 0 {
                position = base &+ (try moof.i32(i))
                i += 4
            }
            var firstFlags: Int64?
            if flags & 0x04 != 0 {
                firstFlags = try moof.u32(i)
                i += 4
            }
            for s in 0..<count {
                var duration = defaultDuration
                var size = defaultSize
                var sampleFlags = (s == 0 ? firstFlags : nil) ?? defaultFlags
                var cts: Int64 = 0
                if flags & 0x100 != 0 { duration = try moof.u32(i); i += 4 }
                if flags & 0x200 != 0 { size = try moof.u32(i); i += 4 }
                if flags & 0x400 != 0 { sampleFlags = try moof.u32(i); i += 4 }
                if flags & 0x800 != 0 {
                    cts = version == 0 ? try moof.u32(i) : try moof.i32(i)
                    i += 4
                }
                guard position >= 0, size <= length, position <= length - size else { throw DashMuxError.malformed("sample outside file") }
                offsets.append(position)
                sizes.append(size)
                durations.append(duration)
                // depends_on == 2 is an I frame; unset falls back to the run's first sample.
                let dependsOn = (sampleFlags >> 24) & 0x3
                if dependsOn == 2 || (dependsOn == 0 && firstFlags != nil && s == 0) {
                    sync.append(Int64(durations.count))
                }
                if let last = ctsRuns.last, last.value == cts {
                    ctsRuns[ctsRuns.count - 1].count += 1
                } else {
                    ctsRuns.append((1, cts))
                }
                position += size
            }
            return position
        }

        func copySample(_ index: Int, to output: BufferedOutput) throws {
            try handle.seek(toOffset: UInt64(offsets[index]))
            var remaining = Int(sizes[index])
            while remaining > 0 {
                guard let data = try handle.read(upToCount: min(remaining, 1 << 20)), !data.isEmpty else {
                    throw DashMuxError.malformed("truncated file")
                }
                try output.write(data)
                remaining -= data.count
            }
        }
    }

    // MARK: Writing

    final class BufferedOutput {
        private let handle: FileHandle
        private var buffer = Data()

        init(_ handle: FileHandle) { self.handle = handle }

        func write(_ data: Data) throws {
            buffer.append(data)
            if buffer.count >= 1 << 20 { try flush() }
        }

        func flush() throws {
            try handle.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
        }
    }

    /// The mdat header grows to 16 bytes once the payload no longer fits a 32-bit size.
    static func mdatHeaderSize(payload: Int64) -> Int64 {
        8 + payload > 0xFFFF_FFFF ? 16 : 8
    }

    private enum Mp4Writer {
        struct Chunk {
            let track: Int
            let startSample: Int
            let count: Int
            let bytes: Int64
            let seconds: Double
            var offset: Int64 = 0
        }

        static func write(_ tracks: [Track], to url: URL) throws {
            var chunks: [Chunk] = []
            for (index, track) in tracks.enumerated() {
                let total = track.durations.count
                let average = max(track.totalDuration / Int64(max(total, 1)), 1)
                let perChunk = Int(max(track.timescale / average, 1))
                var start = 0
                var dts: Int64 = 0
                while start < total {
                    let count = min(perChunk, total - start)
                    let range = start..<(start + count)
                    chunks.append(Chunk(
                        track: index, startSample: start, count: count, bytes: track.sizes[range].reduce(0, +),
                        seconds: Double(dts) / Double(track.timescale)))
                    dts = track.durations[range].reduce(dts, &+)
                    start += count
                }
            }
            chunks.sort { ($0.seconds, $0.track) < ($1.seconds, $1.track) }

            let header = ftyp()
            let payload = chunks.reduce(Int64(0)) { $0 + $1.bytes }
            let mdatHeader = DashMuxer.mdatHeaderSize(payload: payload)
            // stco may widen to co64 once offsets are known, which moves the offsets again: repeat until stable.
            var moov = try buildMoov(tracks, chunks)
            for _ in 0..<4 {
                var position = Int64(header.count + moov.count) + mdatHeader
                for index in chunks.indices {
                    chunks[index].offset = position
                    position += chunks[index].bytes
                }
                let rebuilt = try buildMoov(tracks, chunks)
                let stable = rebuilt.count == moov.count
                moov = rebuilt
                if stable { break }
            }

            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            let output = BufferedOutput(handle)
            try output.write(Data(header))
            try output.write(Data(moov))
            if mdatHeader == 16 {
                try output.write(Data(be32(1) + Array("mdat".utf8) + be64(16 + payload)))
            } else {
                try output.write(Data(be32(8 + payload) + Array("mdat".utf8)))
            }
            for chunk in chunks {
                let track = tracks[chunk.track]
                for sample in chunk.startSample..<(chunk.startSample + chunk.count) {
                    try track.copySample(sample, to: output)
                }
            }
            try output.flush()
        }

        private static func u32Checked(_ value: Int64, _ what: String) throws -> [UInt8] {
            guard (0...0xFFFF_FFFF).contains(value) else { throw DashMuxError.unsupported("\(what) exceeds 32 bits") }
            return be32(value)
        }

        /// Double, because a hostile duration times the scale can overflow Int64.
        private static func rescale(_ value: Int64, from source: Int64, to target: Int64) throws -> Int64 {
            let scaled = Double(value) * Double(target) / Double(max(source, 1))
            guard scaled.isFinite, abs(scaled) < 9e15 else { throw DashMuxError.unsupported("duration out of range") }
            return Int64(scaled)
        }

        private static func buildMoov(_ tracks: [Track], _ chunks: [Chunk]) throws -> [UInt8] {
            let durationsMs = try tracks.map { try rescale($0.totalDuration, from: $0.timescale, to: movieTimescale) }

            var mvhd = fullBox(0, 0)
            mvhd += be32(0) + be32(0) + be32(movieTimescale) + (try u32Checked(durationsMs.max() ?? 0, "duration"))
            mvhd += be32(0x0001_0000) + be16(0x0100) + be16(0) + be32(0) + be32(0)
            mvhd += identityMatrix + [UInt8](repeating: 0, count: 24) + be32(Int64(tracks.count + 1))
            var moov = box("mvhd", mvhd)

            for (index, track) in tracks.enumerated() {
                let isAudio = track.handler == audioHandler
                var tkhd = fullBox(0, 3)
                tkhd += be32(0) + be32(0) + be32(Int64(index + 1)) + be32(0) + (try u32Checked(durationsMs[index], "duration"))
                tkhd += [UInt8](repeating: 0, count: 8) + be16(0) + be16(0) + be16(isAudio ? 0x0100 : 0) + be16(0)
                tkhd += track.matrix + be32(track.width) + be32(track.height)
                var trak = box("tkhd", tkhd)

                if !track.edits.isEmpty {
                    var elst = fullBox(0, 0) + be32(Int64(track.edits.count))
                    for edit in track.edits {
                        var segment = track.sourceMovieTimescale > 0 ? try rescale(edit.segment, from: track.sourceMovieTimescale, to: movieTimescale) : edit.segment
                        // A last segment of 0 means "to the end"; some players then show a zero-length bar.
                        if segment == 0 {
                            segment = max(try rescale(track.totalDuration &- edit.mediaTime, from: track.timescale, to: movieTimescale), 0)
                        }
                        elst += be32(segment) + be32(edit.mediaTime) + be32(edit.rate)
                    }
                    trak += box("edts", box("elst", elst))
                }

                var mdhd = fullBox(0, 0)
                mdhd += be32(0) + be32(0) + (try u32Checked(track.timescale, "timescale")) + (try u32Checked(track.totalDuration, "duration"))
                mdhd += be16(track.language) + be16(0)
                var mdia = box("mdhd", mdhd)

                var hdlr = fullBox(0, 0) + be32(0) + Array(track.handler.utf8) + [UInt8](repeating: 0, count: 12)
                hdlr += Array((isAudio ? "SoundHandler" : "VideoHandler").utf8) + [0]
                mdia += box("hdlr", hdlr)

                var minf = isAudio
                    ? box("smhd", fullBox(0, 0) + be16(0) + be16(0))
                    : box("vmhd", fullBox(0, 1) + [UInt8](repeating: 0, count: 8))
                let dref = fullBox(0, 0) + be32(1) + box("url ", fullBox(0, 1))
                minf += box("dinf", box("dref", dref))
                minf += box("stbl", try sampleTable(track, chunks.filter { $0.track == index }))
                mdia += box("minf", minf)
                trak += box("mdia", mdia)
                moov += box("trak", trak)
            }
            return box("moov", moov)
        }

        private static func sampleTable(_ track: Track, _ mine: [Chunk]) throws -> [UInt8] {
            var stbl = track.stsd

            var sttsRuns: [(count: Int64, value: Int64)] = []
            for duration in track.durations {
                if let last = sttsRuns.last, last.value == duration {
                    sttsRuns[sttsRuns.count - 1].count += 1
                } else {
                    sttsRuns.append((1, duration))
                }
            }
            var stts = fullBox(0, 0) + be32(Int64(sttsRuns.count))
            for run in sttsRuns { stts += be32(run.count) + be32(run.value) }
            stbl += box("stts", stts)

            if track.ctsRuns.contains(where: { $0.value != 0 }) {
                let negative = track.ctsRuns.contains { $0.value < 0 }
                var ctts = fullBox(negative ? 1 : 0, 0) + be32(Int64(track.ctsRuns.count))
                for run in track.ctsRuns { ctts += be32(run.count) + be32(run.value) }
                stbl += box("ctts", ctts)
            }

            if track.handler == videoHandler, !track.sync.isEmpty, track.sync.count != track.durations.count {
                var stss = fullBox(0, 0) + be32(Int64(track.sync.count))
                for sample in track.sync { stss += be32(sample) }
                stbl += box("stss", stss)
            }

            var stsz = fullBox(0, 0) + be32(0) + be32(Int64(track.sizes.count))
            stsz.reserveCapacity(stsz.count + track.sizes.count * 4)
            for size in track.sizes { stsz += be32(size) }
            stbl += box("stsz", stsz)

            var stscRuns: [(first: Int64, count: Int64)] = []
            for (index, chunk) in mine.enumerated() where stscRuns.last?.count != Int64(chunk.count) {
                stscRuns.append((Int64(index + 1), Int64(chunk.count)))
            }
            var stsc = fullBox(0, 0) + be32(Int64(stscRuns.count))
            for run in stscRuns { stsc += be32(run.first) + be32(run.count) + be32(1) }
            stbl += box("stsc", stsc)

            let wide = mine.contains { $0.offset > 0xFFFF_FFFF }
            var stco = fullBox(0, 0) + be32(Int64(mine.count))
            for chunk in mine { stco += wide ? be64(chunk.offset) : be32(chunk.offset) }
            stbl += box(wide ? "co64" : "stco", stco)
            return stbl
        }

        private static func ftyp() -> [UInt8] {
            box("ftyp", Array("isom".utf8) + be32(512) + Array("isomiso2avc1mp41".utf8))
        }

        private static let identityMatrix: [UInt8] =
            be32(0x0001_0000) + be32(0) + be32(0) + be32(0) + be32(0x0001_0000) + be32(0) + be32(0) + be32(0) + be32(0x4000_0000)

        private static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
            be32(Int64(8 + payload.count)) + Array(type.utf8) + payload
        }

        private static func fullBox(_ version: UInt8, _ flags: UInt32) -> [UInt8] {
            [version, UInt8(flags >> 16 & 0xFF), UInt8(flags >> 8 & 0xFF), UInt8(flags & 0xFF)]
        }

        private static func be16(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }

        /// Truncates on purpose: negative edit times and composition offsets are stored two's complement.
        private static func be32(_ value: Int64) -> [UInt8] {
            let bits = UInt32(truncatingIfNeeded: value)
            return [UInt8(bits >> 24), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits & 0xFF)]
        }

        private static func be64(_ value: Int64) -> [UInt8] {
            (0..<8).map { UInt8(truncatingIfNeeded: value >> (56 - 8 * $0)) }
        }
    }
}
