import AppKit

public enum CaptureImageTransform:CaseIterable,Sendable,Equatable {
    case rotateClockwise,rotateCounterclockwise,flipHorizontal,flipVertical
    func applying(to image:CGImage) throws -> CGImage {
        let rotated=self == .rotateClockwise || self == .rotateCounterclockwise
        let width=rotated ? image.height : image.width,height=rotated ? image.width : image.height
        guard let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {throw CaptureFailure.invalidImage}
        switch self {
        case .rotateClockwise:context.translateBy(x:0,y:CGFloat(height));context.rotate(by: -.pi/2)
        case .rotateCounterclockwise:context.translateBy(x:CGFloat(width),y:0);context.rotate(by: .pi/2)
        case .flipHorizontal:context.translateBy(x:CGFloat(width),y:0);context.scaleBy(x:-1,y:1)
        case .flipVertical:context.translateBy(x:0,y:CGFloat(height));context.scaleBy(x:1,y:-1)
        }
        context.interpolationQuality = .none
        context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        guard let output=context.makeImage() else {throw CaptureFailure.invalidImage};return output
    }
}
