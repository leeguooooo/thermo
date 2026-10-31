import XCTest
@testable import MediaToolsKit

private func be32(_ v: Int) -> [UInt8] { [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: v >> $0) } }
private func be16(_ v: Int) -> [UInt8] { [8, 0].map { UInt8(truncatingIfNeeded: v >> $0) } }
private func box(_ type: String, _ body: [UInt8]) -> [UInt8] { be32(body.count + 8) + Array(type.utf8) + body }
private func zeros(_ n: Int) -> [UInt8] { [UInt8](repeating: 0, count: n) }

/// Builds a one-track fragmented MP4 the way Bilibili does: durations only in trex or tfhd.
private struct Fragmented {
    var handler: String
    var timescale = 1000
    var trexDuration = 0
    var tfhdDuration: Int?
    var defaultSize: Int?
    var defaultFlags: Int?
    var firstSampleFlags: Int?
    var fragments: [[[UInt8]]]
    var cts: [Int]? = nil
    var splitTrun = false

    func moov() -> [UInt8] {
        let tkhd = box("tkhd", zeros(40) + be32(0x10000) + zeros(12) + be32(0x10000) + zeros(12) + be32(0x40000000) + be32(320 << 16) + be32(180 << 16))
        let mdhd = box("mdhd", zeros(12) + be32(timescale) + be32(0) + be16(0x15C7) + be16(0))
        let hdlr = box("hdlr", zeros(8) + Array(handler.utf8) + zeros(13))
        let stsd = box("stsd", zeros(4) + be32(0))
        let minf = box("minf", box("stbl", stsd))
        let trak = box("trak", tkhd + box("mdia", mdhd + hdlr + minf))
        let trex = box("trex", zeros(4) + be32(1) + be32(1) + be32(trexDuration) + be32(0) + be32(0))
        return box("moov", box("mvhd", zeros(12) + be32(1000) + zeros(84)) + trak + box("mvex", trex))
    }

    func moof(_ samples: [[UInt8]], index: Int) -> [UInt8] {
        var flags = 0x020000
        var tfhdBody: [UInt8] = []
        if let tfhdDuration { flags |= 0x08; tfhdBody += be32(tfhdDuration) }
        if let defaultSize { flags |= 0x10; tfhdBody += be32(defaultSize) }
        if let defaultFlags { flags |= 0x20; tfhdBody += be32(defaultFlags) }
        let tfhd = box("tfhd", be32(flags) + be32(1) + tfhdBody)

        func trun(_ list: [[UInt8]], start: Int, dataOffset: Int?, firstFlags: Int?) -> [UInt8] {
            var trFlags = defaultSize == nil ? 0x200 : 0
            if dataOffset != nil { trFlags |= 0x01 }
            if firstFlags != nil { trFlags |= 0x04 }
            if cts != nil { trFlags |= 0x800 }
            var body = be32(1 << 24 | trFlags) + be32(list.count)
            if let dataOffset { body += be32(dataOffset) }
            if let firstFlags { body += be32(firstFlags) }
            for (i, sample) in list.enumerated() {
                if defaultSize == nil { body += be32(sample.count) }
                if let cts { body += be32(cts[(start + i) % cts.count]) }
            }
            return box("trun", body)
        }
        func build(_ offset: Int) -> [UInt8] {
            let runs = splitTrun
                ? trun(Array(samples.prefix(1)), start: 0, dataOffset: offset, firstFlags: firstSampleFlags) + trun(Array(samples.dropFirst()), start: 1, dataOffset: nil, firstFlags: nil)
                : trun(samples, start: 0, dataOffset: offset, firstFlags: firstSampleFlags)
            return box("moof", box("traf", tfhd + box("tfdt", zeros(8)) + runs))
        }
        return build(build(0).count + 8)
    }

    func file() -> Data {
        var out = box("ftyp", Array("iso5".utf8) + zeros(4)) + moov()
        for (index, samples) in fragments.enumerated() {
            out += moof(samples, index: index)
            out += box("mdat", samples.flatMap { $0 })
        }
        return Data(out)
    }
}

private struct ParsedOutput {
    let bytes: [UInt8]

    func u32(_ i: Int) -> Int { Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3]) }

    func children(_ start: Int, _ end: Int) -> [(String, Int, Int)] {
        var out: [(String, Int, Int)] = []
        var p = start
        while p + 8 <= end {
            let size = u32(p)
            out.append((String(decoding: bytes[(p + 4)..<(p + 8)], as: UTF8.self), p + 8, p + size))
            p += size
        }
        return out
    }

    func path(_ types: String...) -> [(Int, Int)] {
        var level = [(0, bytes.count)]
        for type in types {
            level = level.flatMap { children($0.0, $0.1).filter { $0.0 == type }.map { ($0.1, $0.2) } }
        }
        return level
    }

    /// Follows stsc, stco and stsz back to sample bytes, proving the offsets.
    func samples(track: Int) -> [[UInt8]] {
        let stbl = path("moov", "trak", "mdia", "minf", "stbl")[track]
        func table(_ type: String) -> Int { children(stbl.0, stbl.1).first { $0.0 == type }!.1 }
        let stsz = table("stsz"), stco = table("stco"), stsc = table("stsc")
        let sizes = (0..<u32(stsz + 8)).map { u32(stsz + 12 + 4 * $0) }
        let chunkOffsets = (0..<u32(stco + 4)).map { u32(stco + 8 + 4 * $0) }
        let runs = (0..<u32(stsc + 4)).map { (u32(stsc + 8 + 12 * $0), u32(stsc + 12 + 12 * $0)) }
        var result: [[UInt8]] = []
        var sample = 0
        for (index, offset) in chunkOffsets.enumerated() {
            let perChunk = runs.last { $0.0 <= index + 1 }!.1
            var position = offset
            for _ in 0..<perChunk where sample < sizes.count {
                result.append(Array(bytes[position..<(position + sizes[sample])]))
                position += sizes[sample]
                sample += 1
            }
        }
        return result
    }

    func stts(track: Int) -> [(Int, Int)] {
        let stbl = path("moov", "trak", "mdia", "minf", "stbl")[track]
        let box = children(stbl.0, stbl.1).first { $0.0 == "stts" }!.1
        return (0..<u32(box + 4)).map { (u32(box + 8 + 8 * $0), u32(box + 12 + 8 * $0)) }
    }

    func has(_ type: String, track: Int) -> Bool {
        let stbl = path("moov", "trak", "mdia", "minf", "stbl")[track]
        return children(stbl.0, stbl.1).contains { $0.0 == type }
    }
}

final class DashMuxerTests: XCTestCase {
    private let videoSamples: [[UInt8]] = [[1, 1, 1], [2, 2], [3, 3, 3, 3], [4]]
    private let audioSamples: [[UInt8]] = [[9, 9], [8, 8], [7, 7]]

    private func mux(_ video: Fragmented, _ audio: Fragmented) throws -> ParsedOutput {
        let dir = try makeRoot().url
        let v = dir.appendingPathComponent("v.m4s"), a = dir.appendingPathComponent("a.m4s"), o = dir.appendingPathComponent("o.mp4")
        try video.file().write(to: v)
        try audio.file().write(to: a)
        try DashMuxer.mux(video: v, audio: a, out: o)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".part") }, [])
        return ParsedOutput(bytes: Array(try Data(contentsOf: o)))
    }

    private func video() -> Fragmented {
        Fragmented(handler: "vide", tfhdDuration: 40, firstSampleFlags: 0x02000000, fragments: [Array(videoSamples.prefix(2)), Array(videoSamples.suffix(2))])
    }

    private func audio() -> Fragmented {
        Fragmented(handler: "soun", timescale: 48000, trexDuration: 1024, fragments: [audioSamples])
    }

    func testTimingFromDefaultsAndSampleBytesSurvive() throws {
        let out = try mux(video(), audio())
        XCTAssertEqual(out.samples(track: 0), videoSamples)
        XCTAssertEqual(out.samples(track: 1), audioSamples)
        XCTAssertEqual(out.stts(track: 0).map(\.0), [4])
        XCTAssertEqual(out.stts(track: 0).map(\.1), [40])
        XCTAssertEqual(out.stts(track: 1).map(\.1), [1024])
        let mdhd = out.path("moov", "trak", "mdia", "mdhd")
        XCTAssertEqual(out.u32(mdhd[1].0 + 16), 3072)
    }

    func testKeyframesFromFirstSampleFlags() throws {
        let out = try mux(video(), audio())
        XCTAssertTrue(out.has("stss", track: 0))
        XCTAssertFalse(out.has("stss", track: 1))
    }

    /// YunX reads tfhd 0x10 as flags and 0x20 as size; the spec has them the other way round.
    func testTfhdDefaultSizeAndFlagsInSpecOrder() throws {
        var v = video()
        let samples: [[UInt8]] = [[1, 2], [3, 4], [5, 6]]
        v.fragments = [samples]
        v.defaultSize = 2
        v.defaultFlags = 0x01010000
        let out = try mux(v, audio())
        XCTAssertEqual(out.samples(track: 0), samples)
    }

    func testTrunWithoutDataOffsetContinues() throws {
        var v = video()
        v.fragments = [videoSamples]
        v.splitTrun = true
        XCTAssertEqual(try mux(v, audio()).samples(track: 0), videoSamples)
    }

    func testCompositionOffsetsIncludingNegative() throws {
        var v = video()
        v.cts = [-40, 80]
        let out = try mux(v, audio())
        let stbl = out.path("moov", "trak", "mdia", "minf", "stbl")[0]
        let ctts = out.children(stbl.0, stbl.1).first { $0.0 == "ctts" }!.1
        XCTAssertEqual(out.bytes[ctts], 1)
        XCTAssertEqual(out.u32(ctts + 12), 0xFFFF_FFD8)
    }

    func testLargeMdatHeaderSizeIsAccounted() {
        XCTAssertEqual(DashMuxer.mdatHeaderSize(payload: 100), 8)
        XCTAssertEqual(DashMuxer.mdatHeaderSize(payload: 0xFFFF_FFF7), 8)
        XCTAssertEqual(DashMuxer.mdatHeaderSize(payload: 0xFFFF_FFF8), 16)
    }

    func testRejectsNonFragmentedWrongTrackAndMissingInput() throws {
        let dir = try makeRoot().url
        let plain = dir.appendingPathComponent("p.mp4"), good = dir.appendingPathComponent("g.m4s"), o = dir.appendingPathComponent("o.mp4")
        try Data(box("ftyp", zeros(8)) + box("moov", zeros(8))).write(to: plain)
        try video().file().write(to: good)
        XCTAssertThrowsError(try DashMuxer.mux(video: plain, audio: good, out: o)) { XCTAssertEqual($0 as? DashMuxError, .notFragmented) }
        XCTAssertThrowsError(try DashMuxer.mux(video: good, audio: good, out: o)) { XCTAssertEqual($0 as? DashMuxError, .notFragmented) }
        XCTAssertThrowsError(try DashMuxer.mux(video: dir.appendingPathComponent("none"), audio: good, out: o)) { XCTAssertEqual($0 as? DashMuxError, .inputMissing) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: o.path))
    }

    /// Hostile headers must throw, never trap: this cuts and corrupts a valid file at every position.
    func testTruncatedAndCorruptInputNeverCrashes() throws {
        let dir = try makeRoot().url
        let v = dir.appendingPathComponent("v.m4s"), a = dir.appendingPathComponent("a.m4s"), o = dir.appendingPathComponent("o.mp4")
        try audio().file().write(to: a)
        let valid = video().file()
        for cut in stride(from: 1, to: valid.count, by: 3) {
            try valid.prefix(cut).write(to: v)
            _ = try? DashMuxer.mux(video: v, audio: a, out: o)
        }
        for position in 0..<valid.count {
            var bad = valid
            bad[position] = 0xFF
            try bad.write(to: v)
            _ = try? DashMuxer.mux(video: v, audio: a, out: o)
        }
    }
}
