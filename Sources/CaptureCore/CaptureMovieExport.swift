import AVFoundation
import Foundation

public enum CaptureMovieFormat: String, CaseIterable, Sendable {
    case mp4, gif, webp, apng
    public var fileExtension: String { self == .apng ? "png" : rawValue }
}

public enum CaptureMovieExport {
    public struct Options: Sendable {
        public var format: CaptureMovieFormat = .mp4
        public var start: Double = 0
        public var end: Double?
        public var speed: Double = 1
        public var fps: Int = 16
        public var maxDimension: Int = 1280
        public init() {}
    }
    public static func export(source: URL, to output: URL, options: Options) async throws {
        guard source.resolvingSymlinksInPath() != output.resolvingSymlinksInPath() else { throw CaptureMovieFailure.encoding("Choose a different destination from the recording draft.") }
        let asset = AVURLAsset(url: source), duration = try await asset.load(.duration).seconds
        let end = options.end ?? duration
        guard duration.isFinite, options.start.isFinite, end.isFinite, options.start >= 0, end <= duration+0.001,
              end > options.start, (0.25...4).contains(options.speed), (1...60).contains(options.fps), (32...4096).contains(options.maxDimension) else { throw CaptureMovieFailure.invalidConfiguration }
        let range = CMTimeRange(start: CMTime(seconds: options.start,preferredTimescale: 60_000),
                                duration: CMTime(seconds: end-options.start,preferredTimescale: 60_000))
        // Encode beside the destination and publish only after finalization. Failed exports preserve existing files.
        let stage = output.deletingLastPathComponent().appendingPathComponent(".thermo-export-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:stage,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:stage) }
        let temporary = stage.appendingPathComponent("result."+options.format.fileExtension)
        if options.format == .mp4 {
            try await exportMP4(asset:asset,to:temporary,range:range,speed:options.speed)
        } else {
            let task = Task.detached(priority:.userInitiated) { try exportAnimation(asset:asset,to:temporary,range:range,options:options) }
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath:output.path) {
            _ = try FileManager.default.replaceItemAt(output,withItemAt:temporary)
        } else { try FileManager.default.moveItem(at:temporary,to:output) }
    }
    private static func exportMP4(asset: AVAsset, to output: URL, range: CMTimeRange, speed: Double) async throws {
        let composition = AVMutableComposition()
        for type in [AVMediaType.video,.audio] {
            for source in try await asset.loadTracks(withMediaType:type) {
                let available = try await source.load(.timeRange)
                let intersection = CMTimeRangeGetIntersection(range,otherRange:available)
                guard !intersection.isEmpty else { continue }
                guard let track = composition.addMutableTrack(withMediaType:type,preferredTrackID:kCMPersistentTrackID_Invalid) else { throw CaptureMovieFailure.encoding("Unable to create export track") }
                try track.insertTimeRange(intersection,of:source,at:intersection.start-range.start)
                if type == .video { track.preferredTransform = try await source.load(.preferredTransform) }
            }
        }
        composition.scaleTimeRange(CMTimeRange(start:.zero,duration:range.duration),toDuration:CMTimeMultiplyByFloat64(range.duration,multiplier:1/speed))
        guard let session = AVAssetExportSession(asset:composition,presetName:AVAssetExportPresetHighestQuality), session.supportedFileTypes.contains(.mp4) else { throw CaptureMovieFailure.encoding("MP4 export is unavailable") }
        session.outputURL = output; session.outputFileType = .mp4; session.shouldOptimizeForNetworkUse = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void,Never>) in session.exportAsynchronously { continuation.resume() } }
        } onCancel: { session.cancelExport() }
        guard session.status == .completed else { throw session.error ?? CaptureMovieFailure.encoding("MP4 export failed") }
    }
    private static func exportAnimation(asset: AVAsset, to output: URL, range: CMTimeRange, options: Options) throws {
        let generator=AVAssetImageGenerator(asset:asset); generator.appliesPreferredTrackTransform=true
        generator.maximumSize=CGSize(width:options.maxDimension,height:options.maxDimension)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        try CaptureAnimationWriter.write(to:output,format:options.format,seconds:range.duration.seconds/options.speed,fps:options.fps) { time in
            try generator.copyCGImage(at:CMTime(seconds:range.start.seconds+time*options.speed,preferredTimescale:60000),actualTime:nil)
        }
    }
}
