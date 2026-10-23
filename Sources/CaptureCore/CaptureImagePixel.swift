import AppKit

public struct CaptureImagePixel:Sendable,Equatable {
    /// Pixel coordinates use the top-left image origin.
    public let x:Int
    public let y:Int
    public let color:CapturePinColor
}
public enum CaptureImagePixelFailure:LocalizedError {
    case outsideImage
    public var errorDescription:String? {"Choose a pixel inside the image."}
}
public enum CaptureImagePixelReader {
    /// Convert one confirmed image pixel to straight-alpha sRGB, independent of source layout.
    public static func read(_ image:CGImage,x:Int,y:Int) throws -> CaptureImagePixel {
        guard x>=0,y>=0,x<image.width,y<image.height else {throw CaptureImagePixelFailure.outsideImage}
        guard let pixel=image.cropping(to:CGRect(x:x,y:y,width:1,height:1)),let space=CGColorSpace(name:CGColorSpace.sRGB),
              let context=CGContext(data:nil,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue),let bytes=context.data?.assumingMemoryBound(to:UInt8.self) else {throw CaptureFailure.invalidImage}
        context.interpolationQuality = .none;context.draw(pixel,in:CGRect(x:0,y:0,width:1,height:1))
        let alpha=Int(bytes[3])
        func channel(_ index:Int)->Int {alpha==0 ? 0 : min(255,(Int(bytes[index])*255+alpha/2)/alpha)}
        return .init(x:x,y:y,color:.init(red:channel(0),green:channel(1),blue:channel(2),alpha:Double(alpha)/255))
    }
}
