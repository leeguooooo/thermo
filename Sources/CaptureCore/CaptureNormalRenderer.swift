import AppKit
import AVFoundation
import Foundation
import ImageIO

/// Each renderer owns its decoded-frame cache. Overlay changes never overwrite captured source pixels.
public final class CaptureNormalRenderer {
    public let source:CaptureFrameArchiveSource
    public let edits:CaptureNormalEdits
    public let crop:CGRect
    public let width:Int
    public let height:Int
    private var cacheIndex = -1
    private var cached:CGImage?
    public init(source:CaptureFrameArchiveSource,edits:CaptureNormalEdits,maxDimension:Int = 4096) throws {
        guard edits.valid, (32...4096).contains(maxDimension) else { throw CaptureMovieFailure.invalidConfiguration }
        self.source=source; self.edits=edits
        let w=Double(source.header.width),h=Double(source.header.height)
        let rect=CGRect(x:edits.crop.minX*w,y:edits.crop.minY*h,width:edits.crop.width*w,height:edits.crop.height*h).intersection(CGRect(x:0,y:0,width:w,height:h)).integral
        guard rect.width >= 2,rect.height >= 2 else { throw CaptureMovieFailure.invalidConfiguration }
        crop=rect
        let scale=min(1,Double(maxDimension)/max(rect.width,rect.height))
        width=max(2,Int(rect.width*scale)/2*2); height=max(2,Int(rect.height*scale)/2*2)
    }
    private func index(at time:Double) -> Int {
        var low=0,high=source.frames.count
        while low < high { let mid=(low+high)/2; if source.frames[mid].time <= time { low=mid+1 } else { high=mid } }
        return max(0,low-1)
    }
    private func image(at time:Double) throws -> CGImage {
        let index=index(at:time)
        if index == cacheIndex, let cached { return cached }
        let url=source.frameURL(index)
        guard try CaptureFrameArchiveSource.regular(url),let input=CGImageSourceCreateWithURL(url as CFURL,nil),
              let properties=CGImageSourceCopyPropertiesAtIndex(input,0,nil) as? [CFString:Any],
              (properties[kCGImagePropertyPixelWidth] as? Int) == source.header.width,
              (properties[kCGImagePropertyPixelHeight] as? Int) == source.header.height,
              let image=CGImageSourceCreateImageAtIndex(input,0,nil) else { throw CaptureFailure.invalidImage }
        cacheIndex=index; cached=image; return image
    }
    private func pointer(at time:Double) -> CaptureArchivedPointer? {
        var low=0,high=source.pointers.count
        while low < high { let mid=(low+high)/2; if source.pointers[mid].time <= time { low=mid+1 } else { high=mid } }
        return low > 0 ? source.pointers[low-1] : nil
    }
    public func draw(at time:Double,in context:CGContext,progress:Double = 0,remaining:Double = 0,elapsed:Double? = nil) throws {
        guard time.isFinite, time >= 0, time <= source.duration+0.001 else { throw CaptureMovieFailure.invalidTime }
        let image=try image(at:time),canvas=CGRect(x:0,y:0,width:source.header.width,height:source.header.height)
        context.saveGState(); defer { context.restoreGState() }
        context.clip(to:CGRect(x:0,y:0,width:width,height:height))
        context.clear(CGRect(x:0,y:0,width:width,height:height))
        context.scaleBy(x:Double(width)/crop.width,y:Double(height)/crop.height)
        context.translateBy(x:-crop.minX,y:-crop.minY)
        context.draw(image,in:canvas)
        for annotation in edits.annotations where time >= annotation.start && time < annotation.end {
            if let item=annotation.annotation { CaptureDocument.draw(item,in:context) }
        }
        if let record=pointer(at:time),let x=record.sample.x,let y=record.sample.y {
            let p=CGPoint(x:x*canvas.width,y:y*canvas.height),size=20*source.header.pixelScale*edits.cursorScale
            if edits.showClicks,record.sample.buttons != 0 || record.sample.scroll != 0 && time-record.time < 0.4 {
                context.setFillColor(NSColor.systemOrange.withAlphaComponent(0.45).cgColor)
                context.fillEllipse(in:CGRect(x:p.x-size,y:p.y-size,width:size*2,height:size*2))
                if record.sample.scroll != 0 { drawText(record.sample.scroll > 0 ? "↑" : "↓",at:CGPoint(x:p.x+size,y:p.y),size:size,in:context) }
            }
            if edits.showCursor {
                context.beginPath();context.move(to:p);context.addLine(to:CGPoint(x:p.x+size*0.2,y:p.y-size));context.addLine(to:CGPoint(x:p.x+size*0.45,y:p.y-size*0.6));context.addLine(to:CGPoint(x:p.x+size*0.9,y:p.y-size*0.55));context.closePath()
                context.setFillColor(NSColor.white.cgColor);context.setStrokeColor(NSColor.black.cgColor);context.setLineWidth(max(1,source.header.pixelScale));context.drawPath(using:.fillStroke)
            }
        }
        let fontSize=max(12,20*source.header.pixelScale)
        if !edits.watermark.isEmpty { drawText(edits.watermark,at:CGPoint(x:crop.minX+12,y:crop.maxY-fontSize*1.8),size:fontSize,in:context) }
        if edits.progress != .none {
            let value=edits.progress == .remaining ? max(0,remaining) : max(0,elapsed ?? time)
            let text=String(format:"%02d:%02d",Int(value)/60,Int(value)%60)
            context.setFillColor(NSColor.black.withAlphaComponent(0.65).cgColor)
            context.fill(CGRect(x:crop.minX,y:crop.minY,width:crop.width,height:fontSize*1.8))
            context.setFillColor(NSColor.systemBlue.cgColor)
            context.fill(CGRect(x:crop.minX,y:crop.minY,width:crop.width*min(1,max(0,progress)),height:max(2,source.header.pixelScale*2)))
            drawText(text,at:CGPoint(x:crop.minX+12,y:crop.minY+fontSize*0.3),size:fontSize,in:context)
        }
    }
    private func drawText(_ text:String,at point:CGPoint,size:Double,in context:CGContext) {
        NSGraphicsContext.saveGraphicsState();defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:false)
        let shadow=NSShadow();shadow.shadowColor=NSColor.black;shadow.shadowBlurRadius=3;shadow.shadowOffset=CGSize(width:1,height:-1)
        (text as NSString).draw(at:point,withAttributes:[.font:NSFont.systemFont(ofSize:size,weight:.medium),.foregroundColor:NSColor.white,.shadow:shadow])
    }
    public func image(at time:Double,progress:Double = 0,remaining:Double = 0,elapsed:Double? = nil) throws -> CGImage {
        guard let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureFailure.invalidImage }
        try draw(at:time,in:context,progress:progress,remaining:remaining,elapsed:elapsed)
        guard let image=context.makeImage() else { throw CaptureFailure.invalidImage };return image
    }
}

public enum CaptureNormalExport {
    public static func export(source:CaptureFrameArchiveSource,to output:URL,edits:CaptureNormalEdits,options:CaptureMovieExport.Options,
                              progress:@escaping @Sendable(Double)->Void = { _ in }) async throws {
        let requestedEnd=options.end ?? source.duration
        guard edits.valid,options.start.isFinite,requestedEnd.isFinite,options.start >= 0,requestedEnd <= source.duration+0.001,requestedEnd > options.start,
              (0.25...4).contains(options.speed),(1...60).contains(options.fps) else { throw CaptureMovieFailure.invalidConfiguration }
        let end=min(requestedEnd,source.duration)
        guard end > options.start else { throw CaptureMovieFailure.invalidConfiguration }
        let resolved=output.resolvingSymlinksInPath().path,archive=source.root.resolvingSymlinksInPath().path
        guard resolved != archive,!resolved.hasPrefix(archive+"/") else { throw CaptureMovieFailure.encoding("Export outside the editable recording source folder.") }
        let stage=output.deletingLastPathComponent().appendingPathComponent(".thermo-normal-export-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:stage,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:stage) }
        let result=stage.appendingPathComponent("result."+options.format.fileExtension)
        let seconds=(end-options.start)/options.speed
        guard seconds.isFinite,CMTime(seconds:seconds,preferredTimescale:60000).isNumeric,ceil(seconds*Double(options.fps)) < Double(Int.max) else { throw CaptureMovieFailure.invalidConfiguration }
        if options.format == .mp4 {
            guard [5,16,24,30,60].contains(options.fps) else { throw CaptureMovieFailure.invalidConfiguration }
            let video=stage.appendingPathComponent("video.mp4")
            let task=Task.detached(priority:.userInitiated) { try await renderMovie(source:source,to:video,edits:edits,options:options,end:end,progress:progress) }
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            if let audio=source.audioURL,edits.systemVolume > 0 {
                let aac=stage.appendingPathComponent("audio.m4a")
                let available=try await exportAudio(source:audio,to:aac,options:options,end:end,volume:edits.systemVolume)
                if available { try await mux(video:video,audio:aac,to:result,duration:seconds) }
                else { try FileManager.default.moveItem(at:video,to:result) }
            } else { try FileManager.default.moveItem(at:video,to:result) }
        } else {
            let task=Task.detached(priority:.userInitiated) {
                let renderer=try CaptureNormalRenderer(source:source,edits:edits,maxDimension:options.maxDimension)
                try CaptureAnimationWriter.write(to:result,format:options.format,seconds:seconds,fps:options.fps,progress:progress) { time in
                    try renderer.image(at:options.start+time*options.speed,progress:time/seconds,remaining:seconds-time,elapsed:time)
                }
            }
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath:output.path) { _=try FileManager.default.replaceItemAt(output,withItemAt:result) }
        else { try FileManager.default.moveItem(at:result,to:output) }
        progress(1)
    }
    private static func renderMovie(source:CaptureFrameArchiveSource,to output:URL,edits:CaptureNormalEdits,options:CaptureMovieExport.Options,end:Double,
                                    progress:@escaping @Sendable(Double)->Void) async throws {
        let renderer=try CaptureNormalRenderer(source:source,edits:edits,maxDimension:options.maxDimension)
        let seconds=(end-options.start)/options.speed,count=Int(ceil(seconds*Double(options.fps)))
        let writer=try CaptureMovieWriter(url:output,width:renderer.width,height:renderer.height,fps:options.fps,
            bitRate:min(100_000_000,max(100_000,renderer.width*renderer.height*options.fps/3)))
        var pool:CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault,nil,[kCVPixelBufferPixelFormatTypeKey:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey:renderer.width,kCVPixelBufferHeightKey:renderer.height,kCVPixelBufferCGImageCompatibilityKey:true,kCVPixelBufferCGBitmapContextCompatibilityKey:true] as CFDictionary,&pool) == kCVReturnSuccess,let pool else { throw CaptureFailure.exportFailed }
        do {
            for index in 0..<count {
                try Task.checkCancellation()
                let time=Double(index)/Double(options.fps)
                let buffer:CVPixelBuffer=try autoreleasepool {
                    var output:CVPixelBuffer?
                    guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,pool,&output) == kCVReturnSuccess,let output else { throw CaptureFailure.exportFailed }
                    CVPixelBufferLockBaseAddress(output,[]);defer { CVPixelBufferUnlockBaseAddress(output,[]) }
                    guard let context=CGContext(data:CVPixelBufferGetBaseAddress(output),width:renderer.width,height:renderer.height,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(output),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue) else { throw CaptureFailure.exportFailed }
                    try renderer.draw(at:options.start+time*options.speed,in:context,progress:time/seconds,remaining:seconds-time,elapsed:time)
                    return output
                }
                var appended=false
                for _ in 0..<500 {
                    if try writer.appendVideo(buffer,at:CMTime(seconds:time,preferredTimescale:60000)) { appended=true;break }
                    try await Task.sleep(nanoseconds:10_000_000)
                }
                guard appended else { throw CaptureMovieFailure.encoding("Video encoder stalled.") }
                if index%max(1,count/100) == 0 { progress(Double(index+1)/Double(count)*0.9) }
            }
            _=try await writer.finish(at:CMTime(seconds:seconds,preferredTimescale:60000))
        } catch { writer.cancel();throw error }
    }
    private static func exportAudio(source:URL,to output:URL,options:CaptureMovieExport.Options,end:Double,volume:Double) async throws -> Bool {
        let asset=AVURLAsset(url:source),composition=AVMutableComposition()
        guard let input=try await asset.loadTracks(withMediaType:.audio).first else { return false }
        let requested=CMTimeRange(start:CMTime(seconds:options.start,preferredTimescale:60000),duration:CMTime(seconds:end-options.start,preferredTimescale:60000))
        let range=CMTimeRangeGetIntersection(requested,otherRange:try await input.load(.timeRange))
        guard !range.isEmpty,let track=composition.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid) else { return false }
        try track.insertTimeRange(range,of:input,at:range.start-requested.start)
        composition.scaleTimeRange(CMTimeRange(start:.zero,duration:requested.duration),toDuration:CMTimeMultiplyByFloat64(requested.duration,multiplier:1/options.speed))
        let parameters=AVMutableAudioMixInputParameters(track:track);parameters.setVolume(Float(volume),at:.zero);parameters.audioTimePitchAlgorithm = .timeDomain
        let mix=AVMutableAudioMix();mix.inputParameters=[parameters]
        guard let session=AVAssetExportSession(asset:composition,presetName:AVAssetExportPresetAppleM4A) else { throw CaptureFailure.exportFailed }
        session.audioMix=mix;session.outputURL=output;session.outputFileType = .m4a
        try await finish(session);return true
    }
    private static func mux(video:URL,audio:URL,to output:URL,duration:Double) async throws {
        let composition=AVMutableComposition(),range=CMTimeRange(start:.zero,duration:CMTime(seconds:duration,preferredTimescale:60000))
        for (url,type) in [(video,AVMediaType.video),(audio,.audio)] {
            let asset=AVURLAsset(url:url)
            for input in try await asset.loadTracks(withMediaType:type) {
                let intersection=CMTimeRangeGetIntersection(range,otherRange:try await input.load(.timeRange))
                guard !intersection.isEmpty,let track=composition.addMutableTrack(withMediaType:type,preferredTrackID:kCMPersistentTrackID_Invalid) else { continue }
                try track.insertTimeRange(intersection,of:input,at:intersection.start)
            }
        }
        guard let session=AVAssetExportSession(asset:composition,presetName:AVAssetExportPresetPassthrough) else { throw CaptureFailure.exportFailed }
        session.outputURL=output;session.outputFileType = .mp4;session.timeRange=range
        try await finish(session)
    }
    private static func finish(_ session:AVAssetExportSession) async throws {
        await withTaskCancellationHandler { await withCheckedContinuation { (continuation:CheckedContinuation<Void,Never>) in session.exportAsynchronously { continuation.resume() } } } onCancel: { session.cancelExport() }
        guard session.status == .completed else { throw session.error ?? CaptureFailure.exportFailed }
    }
}
