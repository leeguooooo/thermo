// CLI-only fixture: encode production MP4 fragments, then let the parent kill this process.
import AVFoundation
import CaptureCore
import Foundation

@main struct RecordingRecoveryProbe {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { throw CaptureMovieFailure.invalidConfiguration }
        let mode = CommandLine.arguments[1], root = URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
        let store = CaptureRecordingDraftStore(root:root)
        if mode == "encode" {
            let draft = try store.create()
            let writer = try CaptureMovieWriter(url:store.movie(draft.id),width:160,height:120,fps:5)
            for index in 0..<50 {
                var result:CVPixelBuffer?
                CVPixelBufferCreate(kCFAllocatorDefault,160,120,kCVPixelFormatType_32BGRA,[kCVPixelBufferCGImageCompatibilityKey:true,kCVPixelBufferCGBitmapContextCompatibilityKey:true] as CFDictionary,&result)
                guard let buffer = result else { throw CaptureFailure.invalidImage }
                CVPixelBufferLockBaseAddress(buffer,[])
                let ctx = CGContext(data:CVPixelBufferGetBaseAddress(buffer),width:160,height:120,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(buffer),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue)!
                ctx.setFillColor(CGColor(red:Double(index%2),green:0.2,blue:Double((index+1)%2),alpha:1)); ctx.fill(CGRect(x:0,y:0,width:160,height:120))
                CVPixelBufferUnlockBaseAddress(buffer,[])
                while try !writer.appendVideo(buffer,at:CMTime(seconds:100+Double(index)/5,preferredTimescale:60000)) { try await Task.sleep(nanoseconds:1_000_000) }
            }
            print("READY \(draft.id.uuidString)"); fflush(stdout)
            while true {
                _ = writer.statistics(at:CMTime(seconds:110,preferredTimescale:60000))
                try await Task.sleep(nanoseconds:100_000_000)
            }
        } else if mode == "inspect" {
            guard let draft = try store.list().first else { throw CaptureMovieFailure.noFrames }
            let asset = AVURLAsset(url:store.movie(draft.id))
            let playable = try await asset.load(.isPlayable), duration = try await asset.load(.duration)
            let image = try AVAssetImageGenerator(asset:asset).copyCGImage(at:CMTime(seconds:1,preferredTimescale:600),actualTime:nil)
            let values:[String:Any] = ["playable":playable,"duration":duration.seconds,"width":image.width,"height":image.height,"draftStatus":draft.status.rawValue]
            let data = try JSONSerialization.data(withJSONObject:values,options:.sortedKeys)
            print(String(decoding:data,as:UTF8.self))
        } else { throw CaptureMovieFailure.invalidConfiguration }
    }
}
