import Foundation
import XCTest
@testable import DownloadKit

/// Scripted origin for HLS: path to response, recording each request.
private final class HlsFake: DownloadTransport, @unchecked Sendable {
    typealias Route = (status: Int, headers: [String: String], body: Data)
    let routes: [String: Route]
    private let lock = NSLock()
    private var seen: [FetchRequest] = []
    var requests: [FetchRequest] { lock.withLock { seen } }

    init(_ routes: [String: Route]) { self.routes = routes }

    func fetch(_ request: FetchRequest) async throws -> FetchResponse {
        lock.withLock { seen.append(request) }
        XCTAssertFalse(request.followRedirects)
        guard let route = routes[request.url.absoluteString] else {
            return FakeTransport.response(status: 404, body: Data())
        }
        return FakeTransport.response(status: route.status, headers: route.headers, body: route.body)
    }
}

final class PortedHelpersTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ported-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func text(_ value: String) -> HlsFake.Route { (200, [:], Data(value.utf8)) }

    // MARK: HLS

    func testHlsFollowsVariantMapAndSegmentsInOrder() async throws {
        let fake = HlsFake([
            "https://a.test/m.m3u8": text("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\r\nv/i.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=2\nother.m3u8\n"),
            "https://a.test/v/i.m3u8": text("#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:1,\ns1.ts\n#EXTINF:1,\n/abs/s2.ts\n"),
            "https://a.test/v/init.mp4": text("I"),
            "https://a.test/v/s1.ts": text("A"),
            "https://a.test/abs/s2.ts": text("B"),
        ])
        let out = directory.appendingPathComponent("o/v.ts")
        try await HlsDownloader(transport: fake).download(url: "https://a.test/m.m3u8", destination: out)
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "IAB")
    }

    func testHlsDropsCredentialsAcrossOriginsIncludingRedirects() async throws {
        let fake = HlsFake([
            "https://a.test/m.m3u8": text("https://cdn.test/s1.ts\nr.ts\n"),
            "https://cdn.test/s1.ts": text("A"),
            "https://a.test/r.ts": (302, ["Location": "https://cdn.test/s2.ts"], Data()),
            "https://cdn.test/s2.ts": text("B"),
        ])
        let out = directory.appendingPathComponent("v.ts")
        try await HlsDownloader(transport: fake).download(
            url: "https://a.test/m.m3u8", headers: ["Cookie": "c", "Authorization": "t", "Referer": "r", "User-Agent": "u"], destination: out
        )
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "AB")
        for request in fake.requests {
            let isOrigin = request.url.host == "a.test"
            XCTAssertEqual(request.headers["Cookie"] != nil, isOrigin, request.url.absoluteString)
            XCTAssertEqual(request.headers["Authorization"] != nil, isOrigin)
            XCTAssertEqual(request.headers["Referer"] != nil, isOrigin)
            XCTAssertEqual(request.headers["User-Agent"], "u")
        }
    }

    func testHlsRefusesPlainHttpEverywhere() async throws {
        let out = directory.appendingPathComponent("v.ts")
        await assertHlsFails(HlsFake([:]), url: "http://a.test/m.m3u8", .insecureURL)
        await assertHlsFails(HlsFake(["https://a.test/m.m3u8": text("http://a.test/s.ts\n")]), url: "https://a.test/m.m3u8", .insecureURL)
        await assertHlsFails(HlsFake([
            "https://a.test/m.m3u8": (302, ["Location": "http://a.test/m.m3u8"], Data()),
        ]), url: "https://a.test/m.m3u8", .insecureURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    func testHlsRejectsEncryptionByteRangesAndEmptyLists() async {
        for playlist in ["#EXT-X-KEY:METHOD=AES-128\ns.ts\n", "#EXT-X-BYTERANGE:10@0\ns.ts\n"] {
            await assertHlsFails(HlsFake(["https://a.test/m": text(playlist)]), url: "https://a.test/m", .unsupportedPlaylist)
        }
        await assertHlsFails(HlsFake(["https://a.test/m": text("#EXTM3U\n")]), url: "https://a.test/m", .emptyPlaylist)
    }

    func testHlsRedirectLoopIsBounded() async {
        let fake = HlsFake(["https://a.test/m": (302, ["Location": "/m"], Data())])
        await assertHlsFails(fake, url: "https://a.test/m", .tooManyRedirects)
        XCTAssertEqual(fake.requests.count, HlsDownloader.maxRedirects + 1)
    }

    func testHlsFailureDeletesThePartialFile() async throws {
        let fake = HlsFake(["https://a.test/m": text("a.ts\nb.ts\n"), "https://a.test/a.ts": text("A")])
        let out = directory.appendingPathComponent("v.ts")
        do {
            try await HlsDownloader(transport: fake).download(url: "https://a.test/m", destination: out)
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? HlsError, .httpStatus(404))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    func testHlsKeepsExistingFilesAndQuarantinesOutput() async throws {
        let fake = HlsFake(["https://a.test/m": text("a.ts\n"), "https://a.test/a.ts": text("A")])
        let out = directory.appendingPathComponent("v.ts")
        try Data("old".utf8).write(to: out)
        let saved = try await HlsDownloader(transport: fake).download(url: "https://a.test/m", destination: out)
        XCTAssertEqual(saved.lastPathComponent, "v (1).ts")
        XCTAssertEqual(try Data(contentsOf: out), Data("old".utf8))
        XCTAssertEqual(try Data(contentsOf: saved), Data("A".utf8))
        XCTAssertGreaterThan(getxattr(saved.path, "com.apple.quarantine", nil, 0, 0, 0), 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), ["v (1).ts", "v.ts"])
    }

    func testHlsFailureLeavesExistingFileAlone() async throws {
        let fake = HlsFake(["https://a.test/m": text("a.ts\nb.ts\n"), "https://a.test/a.ts": text("A")])
        let out = directory.appendingPathComponent("v.ts")
        try Data("old".utf8).write(to: out)
        _ = try? await HlsDownloader(transport: fake).download(url: "https://a.test/m", destination: out)
        XCTAssertEqual(try Data(contentsOf: out), Data("old".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["v.ts"])
    }

    func testSavedFileIsQuarantinedWithoutItsURL() throws {
        let source = directory.appendingPathComponent("muxed.mp4")
        try Data([1]).write(to: source)
        let saved = try DownloadSaver.save(source, as: "clip.mp4", in: directory)
        var buffer = [CChar](repeating: 0, count: 512)
        let length = getxattr(saved.path, "com.apple.quarantine", &buffer, 511, 0, 0)
        XCTAssertGreaterThan(length, 0)
        XCTAssertFalse(String(cString: buffer).contains("http"))
    }

    func testHlsSizeLimits() async {
        let big = HlsFake([
            "https://a.test/m": text("a.ts\n"),
            "https://a.test/a.ts": (200, [:], Data(repeating: 1, count: 64)),
        ])
        await assertHlsFails(big, url: "https://a.test/m", .limitExceeded("segment size"), maxSegment: 10)
        await assertHlsFails(big, url: "https://a.test/m", .limitExceeded("total size"), maxTotal: 10)
        let hugePlaylist = HlsFake(["https://a.test/m": (200, [:], Data(repeating: 65, count: 1 << 20 + 1))])
        await assertHlsFails(hugePlaylist, url: "https://a.test/m", .limitExceeded("playlist size"))
        XCTAssertThrowsError(try HlsDownloader.parseSegments(String(repeating: "s\n", count: HlsDownloader.maxSegments + 1)))
    }

    private func assertHlsFails(
        _ fake: HlsFake, url: String, _ expected: HlsError, maxSegment: Int64 = HlsDownloader.maxSegmentBytes,
        maxTotal: Int64 = HlsDownloader.maxTotalBytes, line: UInt = #line
    ) async {
        let out = directory.appendingPathComponent("v.ts")
        do {
            try await HlsDownloader(transport: fake, maxSegmentSize: maxSegment, maxTotalSize: maxTotal).download(url: url, destination: out)
            XCTFail("expected \(expected)", line: line)
        } catch {
            XCTAssertEqual(error as? HlsError, expected, line: line)
        }
    }

    func testHlsPortAndHostComparison() {
        let base = URL(string: "https://a.test/x")!
        XCTAssertTrue(HlsRequestPolicy.sameOrigin(base, URL(string: "https://A.test:443/y")!))
        XCTAssertFalse(HlsRequestPolicy.sameOrigin(base, URL(string: "https://a.test:8443/y")!))
    }

    // MARK: Saver

    func testSanitizeRules() {
        XCTAssertNil(DownloadPathPolicy.sanitize("/etc/passwd", fallbackName: "f"))
        XCTAssertNil(DownloadPathPolicy.sanitize("a/../b", fallbackName: "f"))
        XCTAssertNil(DownloadPathPolicy.sanitize("..\\b", fallbackName: "f"))
        XCTAssertEqual(DownloadPathPolicy.sanitize("a/b/c:d.mp4", fallbackName: "f"), .init(fileName: "c_d.mp4", relativeDirectory: "a/b"))
        XCTAssertEqual(DownloadPathPolicy.sanitize("folder/", fallbackName: "f"), .init(fileName: "f", relativeDirectory: "folder"))
        let long = DownloadPathPolicy.sanitizeName(String(repeating: "x", count: 150) + ".mp4")
        XCTAssertEqual(long, String(repeating: "x", count: 100) + ".mp4")
    }

    func testDestinationStaysInsideAndRefusesSymlinkEscape() throws {
        let root = directory.appendingPathComponent("root")
        let outside = directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)

        let safe = try DownloadSaver.destination(for: "a/b.bin", in: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("a").path))
        XCTAssertEqual(safe.lastPathComponent, "b.bin")
        XCTAssertThrowsError(try DownloadSaver.destination(for: "link/b.bin", in: root))
        XCTAssertThrowsError(try DownloadSaver.destination(for: "../b.bin", in: root))
    }

    func testSaveNeverOverwrites() throws {
        let root = directory.appendingPathComponent("r")
        for body in ["one", "two"] {
            let source = directory.appendingPathComponent("s-\(body)")
            try Data(body.utf8).write(to: source)
            _ = try DownloadSaver.save(source, as: "f.txt", in: root)
        }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("f.txt"), encoding: .utf8), "one")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("f (1).txt"), encoding: .utf8), "two")
    }

    func testDeleteHandlesFoldersAndBlank() throws {
        let folder = directory.appendingPathComponent("t/sub")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertFalse(DownloadSaver.delete("  "))
        XCTAssertTrue(DownloadSaver.delete(directory.appendingPathComponent("t").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    // MARK: Grouping

    func testGroupingSeparatesSameFolderInTwoRoots() {
        let one = DownloadGrouping.Item(fileName: "F/s/a.mp4", savePath: "/x/F/s/a.mp4")
        let two = DownloadGrouping.Item(fileName: "F/s/a.mp4", savePath: "/y/F/s/a.mp4")
        XCTAssertEqual(DownloadGrouping.saveRoot(one, globalRoot: nil), "/x")
        XCTAssertEqual(DownloadGrouping.groupKey(one, globalRoot: nil).folder, "F")
        XCTAssertNotEqual(DownloadGrouping.groupKey(one, globalRoot: nil).root, DownloadGrouping.groupKey(two, globalRoot: nil).root)
    }

    func testGroupingFallsBackForUnfinishedTasks() {
        let item = DownloadGrouping.Item(fileName: "F\\a.mp4", saveDirectory: "/d")
        XCTAssertEqual(DownloadGrouping.saveRoot(item, globalRoot: "/g"), "/d")
        XCTAssertEqual(DownloadGrouping.saveRoot(.init(fileName: "F/a"), globalRoot: "/g"), "/g")
        XCTAssertEqual(DownloadGrouping.normalizeRoot("/g/"), "/g")
        XCTAssertEqual(DownloadGrouping.normalizeRoot("  "), "")
    }

    // MARK: P2P links

    func testMagnet() {
        let hash = "abcdef0123456789abcdef0123456789abcdef01"
        let link = " MAGNET:?xt=urn:btih:\(hash)&dn=My%20C%2B%2B+File&tr=x "
        XCTAssertTrue(MagnetLink.isMagnet(link))
        XCTAssertFalse(MagnetLink.isMagnet("magnet:"))
        XCTAssertEqual(MagnetLink.infoHash(link), hash.uppercased())
        XCTAssertEqual(MagnetLink.displayName(link), "My C+++File")
        XCTAssertEqual(MagnetLink.displayName("magnet:?xt=urn:btih:\(hash)"), "磁力_ABCDEF01")
        XCTAssertEqual(MagnetLink.displayName("magnet:?tr=x"), "磁力任务")
        XCTAssertEqual(MagnetLink.displayName("magnet:?dn=a%0Ab").count, 3)
        XCTAssertEqual(MagnetLink.displayName("magnet:?dn=" + String(repeating: "x", count: 200)).count, 80)
    }

    func testEd2k() {
        let link = "ed2k://|file|a b.iso|1234|ABCDEF|/"
        XCTAssertTrue(Ed2kLink.isEd2k(link))
        XCTAssertFalse(Ed2kLink.isEd2k("ed2k://|server|1.2.3.4|4661|/"))
        XCTAssertEqual(Ed2kLink.fileName(link), "a b.iso")
        XCTAssertEqual(Ed2kLink.fileSize(link), 1234)
        XCTAssertEqual(Ed2kLink.fileSize("ed2k://|file|a|x|h|/"), -1)
    }

    func testP2PRouting() {
        XCTAssertTrue(P2PLink.isTorrentFile("/tmp/x.TORRENT"))
        XCTAssertFalse(P2PLink.isTorrentFile("https://a.test/x.torrent"))
        XCTAssertTrue(P2PLink.matches("magnet:?xt=urn:btih:ab"))
        XCTAssertFalse(P2PLink.matches("https://a.test/f"))
        XCTAssertEqual(P2PLink.displayName("C:\\t\\x.torrent"), "x")
        XCTAssertEqual(P2PLink.platform(for: "ed2k://|file|a|1|h|/"), "ed2k")
        XCTAssertEqual(P2PLink.platform(for: "/a.torrent"), "magnet")
        XCTAssertEqual(P2PLink.knownSize("/a.torrent"), -1)
    }
}
