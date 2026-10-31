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

final class GopeedProvisionerTests: XCTestCase {
    private let directURL = "https://github.com/GopeedLab/gopeed/releases/download/v1.9.3/gopeed-web-v1.9.3-macos-arm64.zip"

    private func release(digest: String?, size: Int) -> [String: Any] {
        var asset: [String: Any] = ["name": "gopeed-web-v1.9.3-macos-arm64.zip", "browser_download_url": directURL, "size": size]
        if let digest { asset["digest"] = digest }
        return ["tag_name": "v1.9.3", "assets": [["name": "gopeed-web-v1.9.3-macos-amd64.zip"], asset]]
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

    func testPicksArm64AssetAndMirror() async throws {
        let transport = FakeTransport()
        transport.on("GET \(GopeedKernelProvisioner.latestRelease.absoluteString)", json: release(digest: "sha256:\(String(repeating: "a", count: 64))", size: 9))
        let plan = try await GopeedKernelProvisioner(root: makeRoot(), transport: transport).resolvePlan(mirrorPrefix: "https://mirror.test/")
        XCTAssertEqual(plan.url.absoluteString, "https://mirror.test/\(directURL)")
        XCTAssertEqual(plan.fallbackURL?.absoluteString, directURL)
        XCTAssertEqual(plan.size, 9)
    }

    func testMirrorIgnoredWithoutDigestOrTLS() async throws {
        let transport = FakeTransport()
        transport.on("GET \(GopeedKernelProvisioner.latestRelease.absoluteString)", json: release(digest: nil, size: 9))
        var plan = try await GopeedKernelProvisioner(root: makeRoot(), transport: transport).resolvePlan(mirrorPrefix: "https://mirror.test/")
        XCTAssertEqual(plan.url.absoluteString, directURL)
        let second = FakeTransport()
        second.on("GET \(GopeedKernelProvisioner.latestRelease.absoluteString)", json: release(digest: "sha256:\(String(repeating: "a", count: 64))", size: 9))
        plan = try await GopeedKernelProvisioner(root: makeRoot(), transport: second).resolvePlan(mirrorPrefix: "http://mirror.test/")
        XCTAssertEqual(plan.url.absoluteString, directURL)
    }

    func testProvisionVerifiesAndInstallsExecutable() async throws {
        let (bytes, _) = try fixture()
        let root = try makeRoot()
        let transport = FakeTransport()
        transport.on("GET \(GopeedKernelProvisioner.latestRelease.absoluteString)", json: release(digest: "sha256:\(sha(bytes))", size: bytes.count))
        transport.on("GET \(directURL)", .init(body: bytes))
        let engine = engine(root)
        _ = try await GopeedKernelProvisioner(root: root, transport: transport).provision(engine: engine)
        XCTAssertNoThrow(try root.validatedExecutable(root.gopeedExecutable))
        let state = await engine.state
        XCTAssertEqual(state, .installed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.temporaryDir.path), [])
    }

    func testChecksumMismatchInstallsNothing() async throws {
        let (bytes, _) = try fixture()
        let root = try makeRoot()
        let transport = FakeTransport()
        transport.on("GET \(GopeedKernelProvisioner.latestRelease.absoluteString)", json: release(digest: "sha256:\(String(repeating: "0", count: 64))", size: bytes.count))
        transport.on("GET \(directURL)", .init(body: bytes))
        do {
            _ = try await GopeedKernelProvisioner(root: root, transport: transport).provision(engine: engine(root))
            XCTFail("expected mismatch")
        } catch {
            XCTAssertEqual(error as? MediaToolsError, .checksumMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.gopeedExecutable.path))
    }

    func testFailedMirrorFallsBackAndTruncationFails() async throws {
        let (bytes, _) = try fixture()
        let root = try makeRoot()
        let transport = FakeTransport()
        transport.on("GET \(GopeedKernelProvisioner.latestRelease.absoluteString)", json: release(digest: "sha256:\(sha(bytes))", size: bytes.count))
        transport.on("GET https://mirror.test/\(directURL)", .init(body: Data(bytes.prefix(4))))
        transport.on("GET \(directURL)", .init(body: bytes))
        _ = try await GopeedKernelProvisioner(root: root, transport: transport).provision(engine: engine(root), mirrorPrefix: "https://mirror.test/")
        XCTAssertEqual(transport.sent.count, 3)
        XCTAssertNoThrow(try root.validatedExecutable(root.gopeedExecutable))
    }

    func testArchiveWithoutKernelFails() async throws {
        let other = try makeRoot().url.appendingPathComponent("readme")
        try writeFakeBinary(other)
        let root = try makeRoot()
        do {
            try await engine(root).installFromArchive(try makeZip(containing: other, at: "readme"))
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? MediaToolsError, .missingInArchive("gopeed"))
        }
    }
}

final class FfmpegProvisionerTests: XCTestCase {
    private func wire(_ tool: FfmpegTool, _ transport: FakeTransport, zip: Data, sidecar: FakeTransport.Reply?) {
        let build = URL(string: "https://ffmpeg.martin-riedl.de/download/macos/arm64/1_9.0/\(tool.rawValue).zip")!
        transport.on("GET \(FfmpegProvisioner.releaseURL(tool).absoluteString)", .init(body: zip, finalURL: build))
        if let sidecar { transport.on("GET \(build.absoluteString).sha256", sidecar) }
    }

    private func zip(_ name: String) throws -> Data {
        let binary = try makeRoot().url.appendingPathComponent(name)
        try writeFakeBinary(binary)
        return try Data(contentsOf: makeZip(containing: binary, at: name))
    }

    func testVerifiesAgainstSidecarOfResolvedBuild() async throws {
        let root = try makeRoot()
        let transport = FakeTransport()
        for tool in FfmpegTool.allCases {
            let bytes = try zip(tool.rawValue)
            wire(tool, transport, zip: bytes, sidecar: .init(body: Data("\(sha(bytes))  \(tool.rawValue).zip\n".utf8)))
        }
        let provisioner = FfmpegProvisioner(root: root, transport: transport)
        let receipts = try await provisioner.provision()
        XCTAssertEqual(receipts.map(\.checksumVerified), [true, true])
        XCTAssertTrue(provisioner.isInstalled)
        XCTAssertNoThrow(try root.validatedExecutable(root.ffprobeExecutable))
        XCTAssertTrue(provisioner.uninstall())
        XCTAssertFalse(provisioner.isInstalled)
    }

    func testMissingSidecarIsReportedUnverified() async throws {
        let transport = FakeTransport()
        wire(.ffmpeg, transport, zip: try zip("ffmpeg"), sidecar: nil)
        let receipts = try await FfmpegProvisioner(root: makeRoot(), transport: transport).provision(tools: [.ffmpeg])
        XCTAssertEqual(receipts, [FfmpegInstallReceipt(tool: .ffmpeg, checksumVerified: false)])
    }

    func testMismatchAndSidecarOutageInstallNothing() async throws {
        let bad: [FakeTransport.Reply] = [.init(body: Data("\(String(repeating: "0", count: 64))  x\n".utf8)), .init(status: 503), .init(body: Data("<html>".utf8))]
        for reply in bad {
            let root = try makeRoot()
            let transport = FakeTransport()
            wire(.ffmpeg, transport, zip: try zip("ffmpeg"), sidecar: reply)
            do {
                _ = try await FfmpegProvisioner(root: root, transport: transport).provision(tools: [.ffmpeg])
                XCTFail("expected failure")
            } catch {}
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
