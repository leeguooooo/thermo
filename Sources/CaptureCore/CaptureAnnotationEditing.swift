import AppKit
import Foundation

extension CaptureAnnotation {
    public var bounds:CGRect {
        guard let first=points.first else { return .zero }
        if tool == .text {
            let size=(text as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:max(18,width*6))])
            return CGRect(origin:first,size:size)
        }
        if tool == .number { let radius=max(18,width*6);return CGRect(x:first.x-radius,y:first.y-radius,width:radius*2,height:radius*2) }
        let xs=points.map(\.x),ys=points.map(\.y)
        let rect=CGRect(x:xs.min()!,y:ys.min()!,width:xs.max()!-xs.min()!,height:ys.max()!-ys.min()!)
        return rect.insetBy(dx:-(tool == .eraser ? width*2 : width/2),dy:-(tool == .eraser ? width*2 : width/2))
    }
    public func moved(dx:CGFloat,dy:CGFloat) -> CaptureAnnotation {
        var result=self;result.points=points.map { CGPoint(x:$0.x+dx,y:$0.y+dy) };return result
    }
    public func resized(to requested:CGRect) -> CaptureAnnotation {
        let old=bounds,new=requested.standardized
        guard old.width > 0,old.height > 0,new.width >= 1,new.height >= 1 else { return self }
        var result=self
        result.points=points.map { CGPoint(x:new.minX+($0.x-old.minX)*new.width/old.width,y:new.minY+($0.y-old.minY)*new.height/old.height) }
        if tool == .text || tool == .number { result.width=width*max(new.width/old.width,new.height/old.height) }
        return result
    }
}
