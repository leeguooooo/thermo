import AppKit
import Foundation

extension CaptureAnnotation {
    public var bounds:CGRect {
        guard let first=points.first else { return .zero }
        if tool == .text {
            let size=(text as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:max(18,width*6))])
            return CGRect(origin:first,size:size)
        }
        if tool == .number {
            let radius=numberRadius,badge=CGRect(x:first.x-radius-width/2,y:first.y-radius-width/2,width:radius*2+width,height:radius*2+width)
            guard options.numberLeader,let last=points.last,hypot(last.x-first.x,last.y-first.y) > radius+4 else{return badge}
            return badge.union(CGRect(x:min(first.x,last.x),y:min(first.y,last.y),width:abs(last.x-first.x),height:abs(last.y-first.y)).insetBy(dx:-max(12,width*4),dy:-max(12,width*4)))
        }
        let xs=points.map(\.x),ys=points.map(\.y)
        let rect=CGRect(x:xs.min()!,y:ys.min()!,width:xs.max()!-xs.min()!,height:ys.max()!-ys.min()!)
        let lineMarkers=tool == .line && (options.lineStart != .none || options.lineEnd != .none)
        let padding=tool == .arrow || lineMarkers ? max(12,width*8) : tool == .line && options.lineJoin == .miter ? width*5 : tool == .eraser ? width*2 : width/2
        let shape=rect.insetBy(dx:-padding,dy:-padding)
        return arrowCommentRect.map{shape.union($0.insetBy(dx:-4,dy:-3))} ?? shape
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
    /// Rescale all selected objects around the same bounds, keeping their relative positions.
    public func resized(from old:CGRect,to new:CGRect) -> CaptureAnnotation {
        guard old.width > 0,old.height > 0,new.width >= 1,new.height >= 1,
              [old.minX,old.minY,old.width,old.height,new.minX,new.minY,new.width,new.height].allSatisfy(\.isFinite) else {return self}
        var result=self
        result.points=points.map {CGPoint(x:new.minX+($0.x-old.minX)*new.width/old.width,y:new.minY+($0.y-old.minY)*new.height/old.height)}
        if tool == .text || tool == .number {result.width=max(1,width*max(new.width/old.width,new.height/old.height))}
        return result
    }
}
