import AppKit

public enum CaptureImageExportFailure:LocalizedError {
    case viewUnavailable,invalidGeometry,pixelLimit
    public var errorDescription:String? {
        switch self {
        case .viewUnavailable:return "The image view is not ready. Open the pin and try again."
        case .invalidGeometry:return "The displayed image size is invalid."
        case .pixelLimit:return "The displayed image exceeds 80 million pixels. Reduce zoom and try again."
        }
    }
}

public enum CaptureImageExport {
    /// Scale refers to logical display points per source pixel. The output uses one pixel per point.
    /// This exports the complete scaled image, excluding editor chrome, pan clipping and window shadow.
    public static func displayed(_ document:CaptureDocument,scale:CGFloat,opacity:Double) throws -> CaptureDocument {
        guard scale.isFinite,scale>0,opacity.isFinite,(0...1).contains(opacity) else {throw CaptureImageExportFailure.invalidGeometry}
        let width=max(1,(document.size.width*scale).rounded()),height=max(1,(document.size.height*scale).rounded())
        guard width.isFinite,height.isFinite else {throw CaptureImageExportFailure.invalidGeometry}
        guard height<=80000000,width<=80000000/height,document.image.height>0,document.image.width<=80000000/document.image.height else {throw CaptureImageExportFailure.pixelLimit}
        guard let ctx=CGContext(data:nil,width:Int(width),height:Int(height),bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {throw CaptureFailure.exportFailed}
        ctx.interpolationQuality = .high;ctx.setAlpha(opacity)
        ctx.draw(try document.rendered(),in:CGRect(x:0,y:0,width:width,height:height))
        guard let output=ctx.makeImage() else {throw CaptureFailure.exportFailed}
        return CaptureDocument(image:output)
    }
}
