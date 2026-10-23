import AppKit
import CoreImage
import Foundation

public struct CaptureAnnotationOptions:Codable,Sendable,Equatable {
    public var strength=12.0
    public var zoom=2.0
    public var opacity=0.6
    public var angle = -30.0
    public var ellipse=false
    public var arrowComment=""
    public var arrowStart:CaptureArrowHead = .none
    public var arrowEnd:CaptureArrowHead = .open
    public var linePattern:CaptureLinePattern = .solid
    public var numberShape:CaptureNumberShape = .circle
    public var numberFilled=true
    public var numberLeader=false
    public var numberFormat:CaptureNumberFormat = .decimal
    public var numberValue:Int?
    public init() {}
    private enum CodingKeys:String,CodingKey {case strength,zoom,opacity,angle,ellipse,arrowComment,arrowStart,arrowEnd,linePattern,numberShape,numberFilled,numberLeader,numberFormat,numberValue}
    public init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        strength=try c.decodeIfPresent(Double.self,forKey:.strength) ?? 12
        zoom=try c.decodeIfPresent(Double.self,forKey:.zoom) ?? 2
        opacity=try c.decodeIfPresent(Double.self,forKey:.opacity) ?? 0.6
        angle=try c.decodeIfPresent(Double.self,forKey:.angle) ?? -30
        ellipse=try c.decodeIfPresent(Bool.self,forKey:.ellipse) ?? false
        arrowComment=try c.decodeIfPresent(String.self,forKey:.arrowComment) ?? ""
        arrowStart=try c.decodeIfPresent(CaptureArrowHead.self,forKey:.arrowStart) ?? .none
        arrowEnd=try c.decodeIfPresent(CaptureArrowHead.self,forKey:.arrowEnd) ?? .open
        linePattern=try c.decodeIfPresent(CaptureLinePattern.self,forKey:.linePattern) ?? .solid
        numberShape=try c.decodeIfPresent(CaptureNumberShape.self,forKey:.numberShape) ?? .circle
        numberFilled=try c.decodeIfPresent(Bool.self,forKey:.numberFilled) ?? true
        numberLeader=try c.decodeIfPresent(Bool.self,forKey:.numberLeader) ?? false
        numberFormat=try c.decodeIfPresent(CaptureNumberFormat.self,forKey:.numberFormat) ?? .decimal
        numberValue=try c.decodeIfPresent(Int.self,forKey:.numberValue)
    }
    public var valid:Bool { arrowComment.count <= 2000 && strength.isFinite && (1...128).contains(strength) && zoom.isFinite && (1...8).contains(zoom) && opacity.isFinite && (0...1).contains(opacity) && angle.isFinite && (-180...180).contains(angle) && (numberValue == nil || (1...3999).contains(numberValue!)) }

}

extension CaptureDocument {
    static func effect(_ item:CaptureAnnotation,in ctx:CGContext,base:CGImage?) throws {
        guard let a=item.points.first,let b=item.points.last else { return }
        let raw=CGRect(x:min(a.x,b.x),y:min(a.y,b.y),width:abs(a.x-b.x),height:abs(a.y-b.y))
        let transform=ctx.ctm
        guard abs(transform.determinant) > 0.000001 else { throw CaptureFailure.invalidImage }
        let bitmap=ctx.makeImage()
        guard let snapshot=bitmap else { throw CaptureFailure.invalidImage }
        let bounds=CGRect(x:0,y:0,width:snapshot.width,height:snapshot.height)
        let rect=raw.applying(transform).standardized.intersection(bounds).integral
        let scale=max(abs(transform.a),abs(transform.d))
        ctx.saveGState();defer { ctx.restoreGState() }
        switch item.tool {
        case .eraser,.eraserRect:
            guard let base else { throw CaptureFailure.invalidImage }
            if item.tool == .eraserRect { ctx.clip(to:raw) }
            else {
                ctx.setLineWidth(max(2,item.width*4));ctx.setLineCap(.round);ctx.setLineJoin(.round)
                ctx.move(to:a)
                if item.points.count == 1 { ctx.addLine(to:CGPoint(x:a.x+0.01,y:a.y)) }
                else { for p in item.points.dropFirst() { ctx.addLine(to:p) } }
                ctx.replacePathWithStrokedPath();ctx.clip()
            }
            ctx.concatenate(transform.inverted());ctx.clear(bounds);ctx.draw(base,in:bounds)
        case .mosaic:
            guard rect.width > 0,rect.height > 0 else { return }
            guard let target=CGContext(data:nil,width:snapshot.width,height:snapshot.height,bitsPerComponent:8,bytesPerRow:snapshot.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),let bytes=target.data?.assumingMemoryBound(to:UInt8.self) else { throw CaptureFailure.invalidImage }
            target.draw(snapshot,in:bounds)
            let block=max(1,Int((item.options.strength*scale).rounded()))
            for y in stride(from:Int(rect.minY),to:Int(rect.maxY),by:block) { for x in stride(from:Int(rect.minX),to:Int(rect.maxX),by:block) {
                let right=min(x+block,Int(rect.maxX)),top=min(y+block,Int(rect.maxY));var sum=[Int](repeating:0,count:4)
                for py in y..<top { for px in x..<right { let offset=((snapshot.height-1-py)*snapshot.width+px)*4;for channel in 0..<4 { sum[channel] += Int(bytes[offset+channel]) } } }
                let count=(right-x)*(top-y)
                for py in y..<top { for px in x..<right { let offset=((snapshot.height-1-py)*snapshot.width+px)*4;for channel in 0..<4 { bytes[offset+channel]=UInt8(sum[channel]/count) } } }
            } }
            guard let output=target.makeImage() else { throw CaptureFailure.invalidImage }
            ctx.clip(to:raw);ctx.concatenate(transform.inverted());ctx.clear(bounds);ctx.draw(output,in:bounds)
        case .blur:
            guard rect.width > 0,rect.height > 0 else { return }
            let input=CIImage(cgImage:snapshot),blurred=input.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:item.options.strength*scale]).cropped(to:bounds)
            guard let output=CIContext(options:[.cacheIntermediates:false]).createCGImage(blurred,from:bounds) else { throw CaptureFailure.invalidImage }
            ctx.clip(to:raw);ctx.concatenate(transform.inverted());ctx.clear(bounds);ctx.draw(output,in:bounds)
        case .spotlight:
            let canvas=bounds.applying(transform.inverted())
            ctx.beginPath();ctx.addRect(canvas)
            if item.options.ellipse { ctx.addEllipse(in:raw) } else { ctx.addRect(raw) }
            ctx.setFillColor(NSColor.black.withAlphaComponent(item.options.opacity).cgColor);ctx.drawPath(using:.eoFill)
        case .magnifier:
            guard rect.width > 1,rect.height > 1 else { return }
            let sample=CGRect(x:rect.midX-rect.width/item.options.zoom/2,y:rect.midY-rect.height/item.options.zoom/2,width:rect.width/item.options.zoom,height:rect.height/item.options.zoom).intersection(bounds)
            let top=CGRect(x:sample.minX,y:bounds.height-sample.maxY,width:sample.width,height:sample.height)
            guard let image=snapshot.cropping(to:top) else { throw CaptureFailure.invalidImage }
            if item.options.ellipse { ctx.addEllipse(in:raw);ctx.clip() } else { ctx.clip(to:raw) }
            ctx.concatenate(transform.inverted());ctx.clear(rect);ctx.interpolationQuality = .high;ctx.draw(image,in:rect)
            ctx.setStrokeColor(item.color.cgColor);ctx.setLineWidth(max(1,item.width*scale))
            if item.options.ellipse { ctx.strokeEllipse(in:rect.insetBy(dx:item.width*scale/2,dy:item.width*scale/2)) } else { ctx.stroke(rect.insetBy(dx:item.width*scale/2,dy:item.width*scale/2)) }
        case .watermark:
            guard !item.text.isEmpty else { return }
            let area=raw.width > 1 && raw.height > 1 ? raw : bounds.applying(transform.inverted())
            ctx.clip(to:area);ctx.setAlpha(item.options.opacity)
            ctx.translateBy(x:area.midX,y:area.midY);ctx.rotate(by:item.options.angle * .pi/180)
            NSGraphicsContext.saveGraphicsState();defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current=NSGraphicsContext(cgContext:ctx,flipped:false)
            let font=NSFont.systemFont(ofSize:max(18,item.width*6),weight:.medium),attributes:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:max(18,item.width*6),weight:.medium),.foregroundColor:item.color]
            let size=(item.text as NSString).size(withAttributes:attributes),extent=hypot(area.width,area.height)
            let stepX=max(40,size.width+font.pointSize*2),stepY=max(30,size.height+font.pointSize*2)
            for y in stride(from:-Double(extent),through:Double(extent),by:Double(stepY)) { for x in stride(from:-Double(extent),through:Double(extent),by:Double(stepX)) { (item.text as NSString).draw(at:CGPoint(x:x,y:y),withAttributes:attributes) } }
        default:break
        }
    }
}
private extension CGAffineTransform { var determinant:CGFloat { a*d-b*c } }
