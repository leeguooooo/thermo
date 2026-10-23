import AppKit
import CoreImage

public struct CaptureImageAdjustments:Codable,Sendable,Equatable {
    public var grayscale=false
    public var inverted=false
    public var brightness=1.0
    public init(grayscale:Bool=false,inverted:Bool=false,brightness:Double=1) {
        self.grayscale=grayscale;self.inverted=inverted;self.brightness=brightness
    }
    public var valid:Bool {brightness.isFinite && (0...2).contains(brightness)}
    public var isDefault:Bool {self == Self()}
    private static let context=CIContext(options:[.workingColorSpace:NSNull(),.outputColorSpace:NSNull(),.cacheIntermediates:false])
    func rendered(_ image:CGImage) throws -> CGImage {
        guard valid else {throw CaptureFailure.invalidImage}
        guard !isDefault else{return image}
        let f=inverted ? -brightness : brightness,bias=inverted ? brightness : 0
        let r=grayscale ? CIVector(x:0.2126*f,y:0.7152*f,z:0.0722*f,w:0) : CIVector(x:f,y:0,z:0,w:0)
        let g=grayscale ? r : CIVector(x:0,y:f,z:0,w:0)
        let b=grayscale ? r : CIVector(x:0,y:0,z:f,w:0)
        let output=CIImage(cgImage:image).applyingFilter("CIColorMatrix",parameters:["inputRVector":r,"inputGVector":g,"inputBVector":b,"inputAVector":CIVector(x:0,y:0,z:0,w:1),"inputBiasVector":CIVector(x:bias,y:bias,z:bias,w:0)])
        guard let result=Self.context.createCGImage(output,from:CGRect(x:0,y:0,width:image.width,height:image.height),format:.RGBA8,colorSpace:CGColorSpaceCreateDeviceRGB()) else {throw CaptureFailure.invalidImage}
        return result
    }
}
