import CWebPEncoder
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Shared animation encoder. Providers return final pixels, so ordinary recordings never pass through a lossy movie proxy.
enum CaptureAnimationWriter {
    static func write(to output:URL,format:CaptureMovieFormat,seconds:Double,fps:Int,
                      progress:(Double)->Void = { _ in },frame:(Double)throws->CGImage) throws {
        let countDouble=max(1,ceil(seconds*Double(fps)-0.000000001))
        guard seconds.isFinite, seconds > 0, (1...60).contains(fps), countDouble >= 1, countDouble <= 10000,
              seconds*1000 <= Double(Int32.max) else { throw CaptureMovieFailure.encoding("Animation export is limited to 10,000 frames. Trim the clip or lower the frame rate.") }
        let requestedCount=Int(countDouble)
        // ImageIO emits APNG frame delays at millisecond precision as well.
        let quantum=format == .gif ? 0.01 : 0.001
        let endTick=max(1,Int((seconds/quantum).rounded()))
        var timings:[(time:Double,tick:Int,delay:Double)]=[]
        for index in 0..<requestedCount {
            let time=Double(index)/Double(fps),tick=Int((time/quantum).rounded())
            let next=index == requestedCount-1 ? endTick : min(endTick,Int((min(seconds,Double(index+1)/Double(fps))/quantum).rounded()))
            if next > tick { timings.append((time,tick,Double(next-tick)*quantum)) }
        }
        let count=timings.count
        guard count > 0 else { throw CaptureFailure.exportFailed }
        var destination:CGImageDestination?
        if format != .webp {
            let type=format == .gif ? UTType.gif.identifier : UTType.png.identifier
            guard let dest=CGImageDestinationCreateWithURL(output as CFURL,type as CFString,count,nil) else { throw CaptureFailure.exportFailed }
            destination=dest
            if format == .gif { CGImageDestinationSetProperties(dest,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary) }
            else { CGImageDestinationSetProperties(dest,[kCGImagePropertyPNGDictionary:[kCGImagePropertyAPNGLoopCount:0]] as CFDictionary) }
        }
        var webp:OpaquePointer?
        defer { if let webp { ThermoWebPEncoderDelete(webp) } }
        for index in 0..<count {
            try Task.checkCancellation()
            try autoreleasepool {
                let timing=timings[index]
                let image=try frame(timing.time)
                let delay=timing.delay
                if format == .webp {
                    if webp == nil { webp=ThermoWebPEncoderCreate(Int32(image.width),Int32(image.height),85) }
                    guard let webp, let ctx=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,
                        space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue), let data=ctx.data else { throw CaptureFailure.exportFailed }
                    ctx.clear(CGRect(x:0,y:0,width:image.width,height:image.height))
                    ctx.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
                    // libwebp accepts straight RGBA; CoreGraphics rendered premultiplied RGBA.
                    let bytes=data.assumingMemoryBound(to:UInt8.self)
                    for offset in stride(from:0,to:image.width*image.height*4,by:4) {
                        let alpha=Int(bytes[offset+3])
                        if alpha > 0 && alpha < 255 {
                            for channel in 0..<3 { bytes[offset+channel]=UInt8(min(255,(Int(bytes[offset+channel])*255+alpha/2)/alpha)) }
                        }
                    }
                    guard ThermoWebPEncoderAdd(webp,data.assumingMemoryBound(to:UInt8.self),Int32(image.width*4),Int32(timing.tick)) != 0 else { throw CaptureFailure.exportFailed }
                } else if let destination {
                    let properties:CFDictionary
                    if format == .gif { properties=[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:delay,kCGImagePropertyGIFUnclampedDelayTime:delay]] as CFDictionary }
                    else { properties=[kCGImagePropertyPNGDictionary:[kCGImagePropertyAPNGDelayTime:delay,kCGImagePropertyAPNGUnclampedDelayTime:delay]] as CFDictionary }
                    CGImageDestinationAddImage(destination,image,properties)
                }
            }
            if index%max(1,count/100) == 0 || index == count-1 { progress(Double(index+1)/Double(count)) }
        }
        if let webp {
            var data:UnsafeMutablePointer<UInt8>?,size=0
            guard ThermoWebPEncoderFinish(webp,Int32(endTick),&data,&size) != 0, let data else { throw CaptureFailure.exportFailed }
            defer { ThermoWebPReleaseData(data) }
            try Data(bytes:data,count:size).write(to:output,options:.atomic)
        } else if let destination { guard CGImageDestinationFinalize(destination) else { throw CaptureFailure.exportFailed } }
    }
}
