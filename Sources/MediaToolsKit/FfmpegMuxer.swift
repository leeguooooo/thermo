import Foundation

/// `-c copy` muxing through the private FFmpeg install; never re-encodes.
public struct FfmpegMuxer: Sendable {
    static let timeout: TimeInterval = 600

    private let root: MediaToolsRoot
    private let runner: ToolRunner

    public init(root: MediaToolsRoot, runner: ToolRunner = ProcessToolRunner()) {
        self.root = root
        self.runner = runner
    }

    public func mux(video: URL, audio: URL, out: URL, onProgress: @escaping @Sendable (Float) -> Void = { _ in }) async -> Bool {
        guard let exe = try? root.validatedExecutable(root.ffmpegExecutable), Self.hasContent(video), Self.hasContent(audio) else { return false }
        let inputs = ["-i", video.path, "-i", audio.path, "-map", "0:v:0", "-map", "1:a:0"]
        return await run(exe, inputs: inputs, out: out, totalUs: await probeDurationUs(video), onProgress)
    }

    /// Single-input remux, used for merged HLS TS output.
    public func remuxToMp4(input: URL, out: URL, onProgress: @escaping @Sendable (Float) -> Void = { _ in }) async -> Bool {
        guard let exe = try? root.validatedExecutable(root.ffmpegExecutable), Self.hasContent(input) else { return false }
        return await run(exe, inputs: ["-i", input.path], out: out, totalUs: await probeDurationUs(input), onProgress)
    }

    private func run(_ exe: URL, inputs: [String], out: URL, totalUs: Int64, _ onProgress: @escaping @Sendable (Float) -> Void) async -> Bool {
        onProgress(0)
        try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: out)
        let arguments = ["-hide_banner", "-loglevel", "error", "-nostats", "-progress", "pipe:1", "-y"]
            + inputs + ["-c", "copy", "-movflags", "+faststart", out.path]
        let result = try? await runner.run(executable: exe, arguments: arguments, timeout: Self.timeout) { line in
            if let progress = Self.progress(line: line, totalUs: totalUs) { onProgress(progress) }
        }
        guard let result, result.exitCode == 0, !result.timedOut, Self.hasContent(out) else {
            try? FileManager.default.removeItem(at: out)
            return false
        }
        onProgress(1)
        return true
    }

    /// `out_time_us` and `out_time_ms` are both microseconds; the second name is a historic FFmpeg quirk.
    static func progress(line: String, totalUs: Int64) -> Float? {
        guard line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms="), totalUs > 0,
              let us = Int64(line.drop(while: { $0 != "=" }).dropFirst().trimmingCharacters(in: .whitespaces)), us > 0 else { return nil }
        return min(1, Float(us) / Float(totalUs))
    }

    private func probeDurationUs(_ file: URL) async -> Int64 {
        guard let probe = try? root.validatedExecutable(root.ffprobeExecutable) else { return 0 }
        let output = LineBox()
        let arguments = ["-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", file.path]
        guard (try? await runner.run(executable: probe, arguments: arguments, timeout: 10, onStdoutLine: { output.add($0) })) != nil else { return 0 }
        guard let seconds = output.lines.compactMap({ Double($0.trimmingCharacters(in: .whitespaces)) }).first, seconds.isFinite, seconds > 0 else { return 0 }
        return Int64(seconds * 1_000_000)
    }

    static func hasContent(_ file: URL) -> Bool {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]))
        return size?.isRegularFile == true && (size?.fileSize ?? 0) > 0
    }
}

/// FFmpeg first; the built-in fragmented-MP4 muxer takes over when FFmpeg is absent or fails.
public struct MediaMuxer: Sendable {
    private let ffmpeg: FfmpegMuxer

    public init(ffmpeg: FfmpegMuxer) {
        self.ffmpeg = ffmpeg
    }

    public func mux(video: URL, audio: URL, out: URL, onProgress: @escaping @Sendable (Float) -> Void = { _ in }) async -> Bool {
        if await ffmpeg.mux(video: video, audio: audio, out: out, onProgress: onProgress) { return true }
        return (try? DashMuxer.mux(video: video, audio: audio, out: out, onProgress: onProgress)) != nil
    }
}

private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ line: String) { lock.withLock { stored.append(line) } }
    var lines: [String] { lock.withLock { stored } }
}
