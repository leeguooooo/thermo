import CryptoKit
import XCTest
@testable import MediaToolsKit

private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

final class MediaToolsRootTests: XCTestCase {
    func testAcceptsOwnBinaryOnly() throws {
        let root = try makeRoot()
        let good = root.gopeedExecutable
        try writeFakeBinary(good)
        XCTAssertEqual(try root.validatedExecutable(good), good)

        let outside = try makeRoot().ffmpegExecutable
        try writeFakeBinary(outside)
        XCTAssertThrowsError(try root.validatedExecutable(outside)) { XCTAssertEqual($0 as? MediaToolsError, .executableOutsideRoot) }
        XCTAssertThrowsError(try root.validatedExecutable(URL(fileURLWithPath: "/usr/bin/true")))
    }

    func testRejectsSymlinkEscapeWritableAndNonMachO() throws {
        let root = try makeRoot()
        let outside = try makeRoot().ffmpegExecutable
        try writeFakeBinary(outside)
        try FileManager.default.createDirectory(at: root.ffmpegBin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.ffmpegExecutable, withDestinationURL: outside)
        XCTAssertThrowsError(try root.validatedExecutable(root.ffmpegExecutable)) { XCTAssertEqual($0 as? MediaToolsError, .executableOutsideRoot) }

        try writeFakeBinary(root.ffprobeExecutable, mode: 0o777)
        XCTAssertThrowsError(try root.validatedExecutable(root.ffprobeExecutable))

        let script = root.gopeedExecutable
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        XCTAssertThrowsError(try root.validatedExecutable(script))
    }

    func testRedactionKeepsMessageDropsQuery() {
        XCTAssertEqual(Redaction.stripURLQueries("failed https://x.test/a.zip?token=s3cret: 403"), "failed https://x.test/a.zip 403")
    }

    func testChecksumParsing() {
        let hex = String(repeating: "aB", count: 32)
        XCTAssertEqual(ToolInstaller.expectedSHA256("sha256:\(hex)"), hex.lowercased())
        XCTAssertEqual(ToolInstaller.expectedSHA256(hex), hex.lowercased())
        XCTAssertNil(ToolInstaller.expectedSHA256(""))
        XCTAssertNil(ToolInstaller.expectedSHA256("sha512:abc"))
    }
}

final class PinnedToolsTests: XCTestCase {
    func testEveryShippedPinIsWellFormedAndSpecific() {
        let pins = [PinnedTools.gopeed] + FfmpegTool.allCases.map(PinnedTools.ffmpeg)
        for pin in pins {
            XCTAssertEqual(pin.url.scheme, "https")
            XCTAssertFalse(pin.url.absoluteString.contains("latest"))
            XCTAssertNotNil(ToolInstaller.expectedSHA256(pin.sha256))
            XCTAssertGreaterThan(pin.size, 0)
        }
    }

    func testVerifyRejectsWrongAndMissingDigests() throws {
        let file = try makeRoot().url.appendingPathComponent("f")
        try Data([1, 2]).write(to: file)
        XCTAssertNoThrow(try ToolInstaller.verify(file, expected: sha(Data([1, 2]))))
        for bad in ["", "sha512:abc", String(repeating: "0", count: 64)] {
            XCTAssertThrowsError(try ToolInstaller.verify(file, expected: bad)) { XCTAssertEqual($0 as? MediaToolsError, .checksumMismatch) }
        }
    }
}

final class GopeedProvisionerTests: XCTestCase {
    private let directURL = "https://github.com/GopeedLab/gopeed/releases/download/v1.9.3/gopeed-web-v1.9.3-macos-arm64.zip"

    private func pin(digest: String, size: Int) -> PinnedTool {
        PinnedTool(url: URL(string: directURL)!, size: Int64(size), sha256: digest)
    }

    private func provisioner(_ root: MediaToolsRoot, _ transport: FakeTransport, digest: String, size: Int) -> GopeedKernelProvisioner {
        GopeedKernelProvisioner(root: root, transport: transport, pin: pin(digest: digest, size: size), version: "v1.9.3")
    }

    private func fixture() throws -> (Data, URL) {
        let binary = try makeRoot().url.appendingPathComponent("gopeed")
        try writeFakeBinary(binary)
        let zip = try makeZip(containing: binary, at: "gopeed-web-v1.9.3/gopeed")
        return (try Data(contentsOf: zip), zip)
    }

    private func engine(_ root: MediaToolsRoot) -> GopeedEngine {
        GopeedEngine(root: root, transport: FakeTransport(), launcher: FakeLauncher(), runner: ProcessToolRunner())
    }

    func testPlanUsesThePinWithoutTheNetwork() throws {
        let transport = FakeTransport()
        let plan = GopeedKernelProvisioner(root: try makeRoot(), transport: transport).resolvePlan(mirrorPrefix: "https://mirror.test/")
        XCTAssertEqual(plan.version, PinnedTools.gopeedVersion)
        XCTAssertEqual(plan.url.absoluteString, "https://mirror.test/\(PinnedTools.gopeed.url.absoluteString)")
        XCTAssertEqual(plan.fallbackURL, PinnedTools.gopeed.url)
        XCTAssertEqual(plan.digest, PinnedTools.gopeed.sha256)
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testKernelFromAnotherPinIsRefusedUntilReprovisioned() async throws {
        let root = try makeRoot()
        let (data, _) = try fixture()
        let digest = sha(data)
        let transport = FakeTransport()
        transport.on("GET \(directURL)", .init(body: data))
        transport.on("GET /api/v1/info", json: ["code": 0, "data": ["version": "1.9.3"]])
        let engine = GopeedEngine(root: root, transport: transport, launcher: FakeLauncher(), runner: ProcessToolRunner(),
                                  readyTimeout: 2, stopTimeout: 0.1, requiredDigest: digest)
        try writeFakeBinary(root.gopeedExecutable)
        var stale = await engine.needsReprovision
        XCTAssertTrue(stale, "an install with no record is not trusted")
        do { _ = try await engine.start(); XCTFail("started an unpinned kernel") } catch { XCTAssertEqual(error as? GopeedError, .kernelNotPinned) }

        _ = try await provisioner(root, transport, digest: digest, size: data.count).provision(engine: engine)
        let pin = await engine.installedPin
        XCTAssertEqual(pin, GopeedInstalledPin(version: "v1.9.3", digest: digest))
        stale = await engine.needsReprovision
        XCTAssertFalse(stale)
        _ = try await engine.start()
        await engine.stop()

        try JSONEncoder().encode(GopeedInstalledPin(version: "v1.0.0", digest: "old")).write(to: root.gopeedPinFile)
        stale = await engine.needsReprovision
        XCTAssertTrue(stale)
    }

    func testPlainHTTPMirrorIgnored() throws {
        let plan = GopeedKernelProvisioner(root: try makeRoot(), transport: FakeTransport()).resolvePlan(mirrorPrefix: "http://mirror.test/")
        XCTAssertEqual(plan.url, PinnedTools.gopeed.url)
        XCTAssertNil(plan.fallbackURL)
    }

    func testProvisionVerifiesAndInstallsExecutable() async throws {
        let (bytes, _) = try fixture()
        let root = try makeRoot()
        let transport = FakeTransport()
        transport.on("GET \(directURL)", .init(body: bytes))
        let engine = engine(root)
        _ = try await provisioner(root, transport, digest: sha(bytes), size: bytes.count).provision(engine: engine)
        XCTAssertNoThrow(try root.validatedExecutable(root.gopeedExecutable))
        let state = await engine.state
        XCTAssertEqual(state, .installed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.temporaryDir.path), [])
    }

    func testMismatchOrMissingDigestInstallsNothing() async throws {
        let (bytes, _) = try fixture()
        for digest in [String(repeating: "0", count: 64), ""] {
            let root = try makeRoot()
            let transport = FakeTransport()
            transport.on("GET \(directURL)", .init(body: bytes))
            do {
                _ = try await provisioner(root, transport, digest: digest, size: bytes.count).provision(engine: engine(root))
                XCTFail("expected mismatch")
            } catch {
                XCTAssertEqual(error as? MediaToolsError, .checksumMismatch)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.gopeedExecutable.path))
        }
    }

    func testFailedMirrorFallsBackAndTruncationFails() async throws {
        let (bytes, _) = try fixture()
        let root = try makeRoot()
        let transport = FakeTransport()
        transport.on("GET https://mirror.test/\(directURL)", .init(body: Data(bytes.prefix(4))))
        transport.on("GET \(directURL)", .init(body: bytes))
        _ = try await provisioner(root, transport, digest: sha(bytes), size: bytes.count).provision(engine: engine(root), mirrorPrefix: "https://mirror.test/")
        XCTAssertEqual(transport.sent.count, 2)
        XCTAssertNoThrow(try root.validatedExecutable(root.gopeedExecutable))
    }

    func testOversizedDownloadIsCutOff() async throws {
        let (bytes, _) = try fixture()
        let root = try makeRoot()
        let transport = FakeTransport()
        transport.on("GET \(directURL)", .init(body: bytes))
        do {
            _ = try await provisioner(root, transport, digest: sha(bytes), size: 4).provision(engine: engine(root))
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? MediaToolsError, .incompleteDownload(expected: 4, actual: Int64(bytes.count)))
        }
    }

    func testArchiveWithoutKernelFails() async throws {
        let other = try makeRoot().url.appendingPathComponent("readme")
        try writeFakeBinary(other)
        let root = try makeRoot()
        let zip = try makeZip(containing: other, at: "readme")
        do {
            try await engine(root).installFromArchive(zip, expectedSHA256: sha(try Data(contentsOf: zip)))
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? MediaToolsError, .missingInArchive("gopeed"))
        }
    }

    func testBareBinaryKeepsQuarantineUnlessDigestMatches() async throws {
        let binary = try makeRoot().url.appendingPathComponent("kernel")
        try writeFakeBinary(binary)
        XCTAssertEqual(setxattr(binary.path, "com.apple.quarantine", "0081;0;Thermo;", 14, 0, 0), 0)

        let root = try makeRoot()
        do {
            try await engine(root).installFromArchive(binary, expectedSHA256: String(repeating: "0", count: 64))
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? MediaToolsError, .checksumMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.gopeedExecutable.path))
        XCTAssertGreaterThan(getxattr(binary.path, "com.apple.quarantine", nil, 0, 0, 0), 0)

        try await engine(root).installFromArchive(binary, expectedSHA256: sha(try Data(contentsOf: binary)))
        XCTAssertLessThan(getxattr(root.gopeedExecutable.path, "com.apple.quarantine", nil, 0, 0, 0), 0)
    }
}

final class FfmpegProvisionerTests: XCTestCase {
    private func url(_ tool: FfmpegTool) -> URL {
        URL(string: "https://ffmpeg.martin-riedl.de/download/macos/arm64/1_9.0/\(tool.rawValue).zip")!
    }

    private func zip(_ name: String) throws -> Data {
        let binary = try makeRoot().url.appendingPathComponent(name)
        try writeFakeBinary(binary)
        return try Data(contentsOf: makeZip(containing: binary, at: name))
    }

    func testInstallsPinnedBuilds() async throws {
        let root = try makeRoot()
        let transport = FakeTransport()
        var pins: [FfmpegTool: PinnedTool] = [:]
        for tool in FfmpegTool.allCases {
            let bytes = try zip(tool.rawValue)
            transport.on("GET \(url(tool).absoluteString)", .init(body: bytes))
            pins[tool] = PinnedTool(url: url(tool), size: Int64(bytes.count), sha256: sha(bytes))
        }
        let chosen = pins
        let provisioner = FfmpegProvisioner(root: root, transport: transport, runner: ProcessToolRunner(), pins: { chosen[$0]! })
        let receipts = try await provisioner.provision()
        XCTAssertEqual(receipts.map(\.tool), FfmpegTool.allCases)
        XCTAssertTrue(provisioner.isInstalled)
        XCTAssertNoThrow(try root.validatedExecutable(root.ffprobeExecutable))
        XCTAssertTrue(provisioner.uninstall())
        XCTAssertFalse(provisioner.isInstalled)
    }

    func testMismatchOrMissingDigestInstallsNothing() async throws {
        let bytes = try zip("ffmpeg")
        for digest in [String(repeating: "0", count: 64), ""] {
            let root = try makeRoot()
            let transport = FakeTransport()
            transport.on("GET \(url(.ffmpeg).absoluteString)", .init(body: bytes))
            let pin = PinnedTool(url: url(.ffmpeg), size: Int64(bytes.count), sha256: digest)
            do {
                _ = try await FfmpegProvisioner(root: root, transport: transport, runner: ProcessToolRunner(), pins: { _ in pin }).provision(tools: [.ffmpeg])
                XCTFail("expected failure")
            } catch {
                XCTAssertEqual(error as? MediaToolsError, .checksumMismatch)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.ffmpegExecutable.path))
        }
    }
}

final class FfmpegMuxerTests: XCTestCase {
    private func inputs(_ root: MediaToolsRoot) throws -> (URL, URL, URL) {
        let video = root.url.appendingPathComponent("v.m4s")
        let audio = root.url.appendingPathComponent("a.m4s")
        try Data([1]).write(to: video)
        try Data([2]).write(to: audio)
        return (video, audio, root.url.appendingPathComponent("o/out.mp4"))
    }

    func testMuxCommandAndProgress() async throws {
        let root = try makeRoot()
        try writeFakeBinary(root.ffmpegExecutable)
        try writeFakeBinary(root.ffprobeExecutable)
        let (video, audio, out) = try inputs(root)
        let runner = FakeRunner()
        runner.handler = { exe, _, line in
            if exe.lastPathComponent == "ffprobe" {
                line("N/A")
                line("10.0")
            } else {
                line("frame=1")
                line("out_time_us=5000000")
                try? Data([9]).write(to: out)
            }
            return ToolResult(exitCode: 0)
        }
        let seen = Locked<[Float]>([])
        let ok = await FfmpegMuxer(root: root, runner: runner).mux(video: video, audio: audio, out: out) { value in seen.mutate { $0.append(value) } }
        XCTAssertTrue(ok)
        XCTAssertEqual(seen.value, [0, 0.5, 1])
        XCTAssertEqual(runner.calls.last?.1, [
            "-hide_banner", "-loglevel", "error", "-nostats", "-progress", "pipe:1", "-y",
            "-i", video.path, "-i", audio.path, "-map", "0:v:0", "-map", "1:a:0",
            "-c", "copy", "-movflags", "+faststart", out.path,
        ])
    }

    func testNoPrivateInstallMeansNoLaunch() async throws {
        let root = try makeRoot()
        let (video, audio, out) = try inputs(root)
        let runner = FakeRunner()
        let ok = await FfmpegMuxer(root: root, runner: runner).mux(video: video, audio: audio, out: out)
        XCTAssertFalse(ok)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testFailureRemovesPartialOutput() async throws {
        let root = try makeRoot()
        try writeFakeBinary(root.ffmpegExecutable)
        let (video, _, out) = try inputs(root)
        let runner = FakeRunner()
        runner.handler = { _, _, _ in
            try? Data([9]).write(to: out)
            return ToolResult(exitCode: 1)
        }
        let ok = await FfmpegMuxer(root: root, runner: runner).remuxToMp4(input: video, out: out)
        XCTAssertFalse(ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    func testProgressLineParsing() {
        XCTAssertEqual(FfmpegMuxer.progress(line: "out_time_ms=2500000", totalUs: 10_000_000), 0.25)
        XCTAssertEqual(FfmpegMuxer.progress(line: "out_time_us=99000000", totalUs: 10_000_000), 1)
        XCTAssertNil(FfmpegMuxer.progress(line: "out_time_us=N/A", totalUs: 10))
        XCTAssertNil(FfmpegMuxer.progress(line: "out_time_us=5", totalUs: 0))
    }

    func testRealRunnerDeliversLastLinesAndExitCode() async throws {
        let lines = Locked<[String]>([])
        let result = try await ProcessToolRunner().run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo one; echo two; echo oops >&2; exit 3"], timeout: 10
        ) { line in lines.mutate { $0.append(line) } }
        XCTAssertEqual(lines.value, ["one", "two"])
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.stderrTail, "oops\n")
    }

    func testRealRunnerTimesOut() async throws {
        let result = try await ProcessToolRunner().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 0.2) { _ in }
        XCTAssertTrue(result.timedOut)
    }

    func testPreviewOnlyTakesWhatAVPlayerPlays() {
        XCTAssertEqual(MediaPreview.kind(of: URL(string: "https://x.test/a.MP4?t=1")!), .mp4)
        XCTAssertEqual(MediaPreview.kind(of: URL(string: "https://x.test/a.m3u8")!), .hls)
        XCTAssertNil(MediaPreview.kind(of: URL(string: "https://x.test/a.mkv")!))
        XCTAssertNil(MediaPreview.makePlayer(url: URL(string: "https://x.test/a.mkv")!))
        XCTAssertNotNil(MediaPreview.makePlayer(url: URL(string: "https://x.test/a.m3u8")!, headers: ["Cookie": "a"]))
    }
}

final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func mutate(_ body: (inout T) -> Void) { lock.withLock { body(&stored) } }
}
