// CLI-only fixture: record production movie fragments or an editable frame archive, then let the parent kill this process.
import AVFoundation
import CaptureCore
import Foundation

@main struct RecordingRecoveryProbe {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { throw CaptureMovieFailure.invalidConfiguration }
        let mode = CommandLine.arguments[1], root = URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
        let store = CaptureRecordingDraftStore(root:root)
        let normal=mode.hasSuffix("-normal")
        if mode == "encode" || mode == "encode-normal" {
            let draft = try store.create(mode:normal ? .normal : .quick)
            let writer = normal ? nil : try CaptureMovieWriter(url:store.movie(draft.id),width:160,height:120,fps:5)
            let archive = normal ? try CaptureFrameArchive(root:store.archive(draft.id),header:.init(width:160,height:120,fps:5)) : nil
            for index in 0..<50 {
                var result:CVPixelBuffer?
                CVPixelBufferCreate(kCFAllocatorDefault,160,120,kCVPixelFormatType_32BGRA,[kCVPixelBufferCGImageCompatibilityKey:true,kCVPixelBufferCGBitmapContextCompatibilityKey:true] as CFDictionary,&result)
                guard let buffer = result else { throw CaptureFailure.invalidImage }
                CVPixelBufferLockBaseAddress(buffer,[])
                let ctx = CGContext(data:CVPixelBufferGetBaseAddress(buffer),width:160,height:120,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(buffer),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue)!
                ctx.setFillColor(CGColor(red:Double(index%2),green:0.2,blue:Double((index+1)%2),alpha:1)); ctx.fill(CGRect(x:0,y:0,width:160,height:120))
                CVPixelBufferUnlockBaseAddress(buffer,[])
                let time=CMTime(seconds:100+Double(index)/5,preferredTimescale:60000)
                if let archive {
                    while try !archive.appendVideo(buffer,at:time) { try await Task.sleep(nanoseconds:1_000_000) }
                    archive.recordPointer(.init(x:Double(index)/50,y:0.5),at:time)
                } else if let writer {
                    while try !writer.appendVideo(buffer,at:time) { try await Task.sleep(nanoseconds:1_000_000) }
                }
            }
            print("READY \(draft.id.uuidString)"); fflush(stdout)
            while true {
                _ = writer?.statistics(at:CMTime(seconds:110,preferredTimescale:60000))
                _ = archive?.statistics(at:CMTime(seconds:110,preferredTimescale:60000))
                try await Task.sleep(nanoseconds:100_000_000)
            }
        } else if mode == "inspect" || mode == "inspect-normal" {
            guard let draft = try store.list().first else { throw CaptureMovieFailure.noFrames }
            var movie=store.movie(draft.id),sourceFrames=0
            if normal {
                let source=try CaptureFrameArchiveSource.load(store.archive(draft.id))
                movie=root.appendingPathComponent("recovered.mp4");sourceFrames=source.frames.count
                var options=CaptureMovieExport.Options();options.fps=5
                try await CaptureNormalExport.export(source:source,to:movie,edits:CaptureNormalEdits(),options:options)
            }
            let asset = AVURLAsset(url:movie)
            let playable = try await asset.load(.isPlayable), duration = try await asset.load(.duration)
            let image = try AVAssetImageGenerator(asset:asset).copyCGImage(at:CMTime(seconds:1,preferredTimescale:600),actualTime:nil)
            let values:[String:Any] = ["playable":playable,"duration":duration.seconds,"width":image.width,"height":image.height,"draftStatus":draft.status.rawValue,"sourceMode":draft.effectiveMode.rawValue,"sourceFrames":sourceFrames]
            let data = try JSONSerialization.data(withJSONObject:values,options:.sortedKeys)
            print(String(decoding:data,as:UTF8.self))
        } else { throw CaptureMovieFailure.invalidConfiguration }
    }
}
