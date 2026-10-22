import AVFoundation
import CWebPEncoder
import Foundation
import ImageIO
import UniformTypeIdentifiers

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
        let seconds = range.duration.seconds/options.speed
        let countDouble = ceil(seconds*Double(options.fps))
        guard countDouble.isFinite, countDouble >= 1, countDouble <= 10000, seconds*1000 <= Double(Int32.max) else { throw CaptureMovieFailure.encoding("Animation export is limited to 10,000 frames. Trim the clip or lower the frame rate.") }
        let count = Int(countDouble)
        let generator = AVAssetImageGenerator(asset:asset); generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width:options.maxDimension,height:options.maxDimension)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        var destination: CGImageDestination?
        if options.format != .webp {
            let type = options.format == .gif ? UTType.gif.identifier : UTType.png.identifier
            guard let dest = CGImageDestinationCreateWithURL(output as CFURL,type as CFString,count,nil) else { throw CaptureFailure.exportFailed }
            destination = dest
            if options.format == .gif { CGImageDestinationSetProperties(dest,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary) }
            else { CGImageDestinationSetProperties(dest,[kCGImagePropertyPNGDictionary:[kCGImagePropertyAPNGLoopCount:0]] as CFDictionary) }
        }
        var webp: OpaquePointer?
        defer { if let webp { ThermoWebPEncoderDelete(webp) } }
        for index in 0..<count {
            try Task.checkCancellation()
            try autoreleasepool {
                let sourceSeconds = range.start.seconds+Double(index)/Double(options.fps)*options.speed
                let image = try generator.copyCGImage(at:CMTime(seconds:sourceSeconds,preferredTimescale:60_000),actualTime:nil)
                let delay = min(1/Double(options.fps),seconds-Double(index)/Double(options.fps))
                if options.format == .webp {
                    if webp == nil { webp = ThermoWebPEncoderCreate(Int32(image.width),Int32(image.height),85) }
                    guard let webp, let ctx = CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,
                        space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue), let data = ctx.data else { throw CaptureFailure.exportFailed }
                    ctx.setFillColor(CGColor(gray:1,alpha:1)); ctx.fill(CGRect(x:0,y:0,width:image.width,height:image.height))
                    ctx.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
                    guard ThermoWebPEncoderAdd(webp,data.assumingMemoryBound(to:UInt8.self),Int32(image.width*4),Int32((Double(index)*1000/Double(options.fps)).rounded())) != 0 else { throw CaptureFailure.exportFailed }
                } else if let destination {
                    let properties: CFDictionary
                    if options.format == .gif { properties = [kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:delay,kCGImagePropertyGIFUnclampedDelayTime:delay]] as CFDictionary }
                    else { properties = [kCGImagePropertyPNGDictionary:[kCGImagePropertyAPNGDelayTime:delay,kCGImagePropertyAPNGUnclampedDelayTime:delay]] as CFDictionary }
                    CGImageDestinationAddImage(destination,image,properties)
                }
            }
        }
        if let webp {
            var data: UnsafeMutablePointer<UInt8>?, size: Int = 0
            guard ThermoWebPEncoderFinish(webp,Int32((seconds*1000).rounded()),&data,&size) != 0, let data else { throw CaptureFailure.exportFailed }
            defer { ThermoWebPReleaseData(data) }
            try Data(bytes:data,count:size).write(to:output,options:.atomic)
        } else if let destination { guard CGImageDestinationFinalize(destination) else { throw CaptureFailure.exportFailed } }
    }
}
