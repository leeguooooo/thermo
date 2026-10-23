import AppKit

public enum CaptureArrowHead:String,Codable,CaseIterable,Sendable {case none,open,filled,diamond,circle}
public enum CaptureLinePattern:String,Codable,CaseIterable,Sendable {case solid,dashed,dotted}
public enum CaptureNumberShape:String,Codable,CaseIterable,Sendable {case circle,square}
public enum CaptureNumberFormat:String,Codable,CaseIterable,Sendable {
    case decimal,alphabetic,roman
    public func label(_ value:Int) -> String {
        guard (1...3999).contains(value) else{return ""}
        switch self {
        case .decimal:return String(value)
        case .alphabetic:
            var number=value,result=""
            while number > 0 {number -= 1;result=String(UnicodeScalar(65+number%26)!)+result;number /= 26}
            return result
        case .roman:
            var number=value,result=""
            for (unit,symbol) in [(1000,"M"),(900,"CM"),(500,"D"),(400,"CD"),(100,"C"),(90,"XC"),(50,"L"),(40,"XL"),(10,"X"),(9,"IX"),(5,"V"),(4,"IV"),(1,"I")] {
                while number >= unit {result += symbol;number -= unit}
            }
            return result
        }
    }
}

extension CaptureAnnotation {
    static func arrowHeadPath(_ style:CaptureArrowHead,tip:CGPoint,awayFrom other:CGPoint,width:CGFloat) -> CGPath? {
        guard style != .none,hypot(tip.x-other.x,tip.y-other.y)>0.01 else{return nil}
        let length=max(12,width*4),angle=atan2(tip.y-other.y,tip.x-other.x),path=CGMutablePath()
        let left=CGPoint(x:tip.x-length*cos(angle-0.5),y:tip.y-length*sin(angle-0.5))
        let right=CGPoint(x:tip.x-length*cos(angle+0.5),y:tip.y-length*sin(angle+0.5))
        switch style {
        case .none:return nil
        case .open:path.move(to:left);path.addLine(to:tip);path.addLine(to:right)
        case .filled:path.move(to:tip);path.addLine(to:left);path.addLine(to:right);path.closeSubpath()
        case .diamond:path.move(to:tip);path.addLine(to:left);path.addLine(to:CGPoint(x:tip.x-2*length*cos(angle),y:tip.y-2*length*sin(angle)));path.addLine(to:right);path.closeSubpath()
        case .circle:path.addEllipse(in:CGRect(x:tip.x-length/2,y:tip.y-length/2,width:length,height:length))
        }
        return path
    }
    func arrowMarkersContain(_ point:CGPoint,tolerance:CGFloat) -> Bool {
        guard tool == .arrow,points.count>=2 else{return false}
        for (style,tip,other) in [(options.arrowStart,points[0],points[1]),(options.arrowEnd,points[points.count-1],points[points.count-2])] {
            guard let path=Self.arrowHeadPath(style,tip:tip,awayFrom:other,width:width) else{continue}
            if style != .open,path.contains(point) {return true}
            if path.copy(strokingWithWidth:width+2*tolerance,lineCap:.round,lineJoin:.round,miterLimit:10).contains(point) {return true}
        }
        return false
    }
    public static func snappedEndpoint(from start:CGPoint,to end:CGPoint,inside size:CGSize) -> CGPoint {
        guard [start.x,start.y,end.x,end.y,size.width,size.height].allSatisfy(\.isFinite),size.width > 0,size.height > 0 else{return end}
        let angle=(atan2(end.y-start.y,end.x-start.x)/(.pi/4)).rounded()*(.pi/4)
        let dx=cos(angle),dy=sin(angle)
        var length=hypot(end.x-start.x,end.y-start.y)
        if abs(dx)>0.000001 {length=min(length,(dx>0 ? size.width-start.x : start.x)/abs(dx))}
        if abs(dy)>0.000001 {length=min(length,(dy>0 ? size.height-start.y : start.y)/abs(dy))}
        return CGPoint(x:start.x+dx*length,y:start.y+dy*length)
    }
    var arrowCommentFont:NSFont {NSFont.systemFont(ofSize:max(14,width*4))}
    public var arrowCommentRect:CGRect? {
        guard tool == .arrow,!options.arrowComment.isEmpty,let a=points.first,let b=points.last else{return nil}
        let size=(options.arrowComment as NSString).boundingRect(with:CGSize(width:360,height:100000),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:arrowCommentFont]).size
        let w=ceil(size.width),h=ceil(size.height),distance=hypot(b.x-a.x,b.y-a.y)
        var nx:CGFloat=0,ny:CGFloat=1
        if distance > 0.01 {nx = -(b.y-a.y)/distance;ny=(b.x-a.x)/distance;if ny<0 {nx = -nx;ny = -ny}}
        let offset=h/2+max(8,width*2)
        return CGRect(x:(a.x+b.x)/2+nx*offset-w/2,y:(a.y+b.y)/2+ny*offset-h/2,width:w,height:h)
    }
    public var numberLabel:String {options.numberValue.map{options.numberFormat.label($0)} ?? text}
    var numberRadius:CGFloat {
        let fontSize=max(18,width*6)
        let labelWidth=(numberLabel as NSString).size(withAttributes:[.font:NSFont.boldSystemFont(ofSize:fontSize)]).width
        return max(fontSize,labelWidth/2+fontSize*0.3)
    }
}

extension CaptureDocument {
    static func styledLine(from start:CGPoint,to end:CGPoint,item:CaptureAnnotation,in ctx:CGContext,startHead:CaptureArrowHead = .none,endHead:CaptureArrowHead = .none,points:[CGPoint]?=nil) {
        let width=max(1,item.width)
        ctx.saveGState();defer{ctx.restoreGState()}
        switch item.options.linePattern {
        case .solid:break
        case .dashed:ctx.setLineDash(phase:0,lengths:[width*3,width*2])
        case .dotted:ctx.setLineDash(phase:0,lengths:[0.1,width*2])
        }
        ctx.move(to:start);for point in (points ?? [start,end]).dropFirst() {ctx.addLine(to:point)};ctx.strokePath();ctx.setLineDash(phase:0,lengths:[])
        guard hypot(end.x-start.x,end.y-start.y) > 0.01 else{return}
        func head(_ style:CaptureArrowHead,at tip:CGPoint,awayFrom other:CGPoint) {
            guard let path=CaptureAnnotation.arrowHeadPath(style,tip:tip,awayFrom:other,width:width) else{return}
            ctx.addPath(path)
            if style == .open {ctx.strokePath()} else {ctx.fillPath()}
        }
        let pathPoints=points ?? [start,end]
        head(startHead,at:start,awayFrom:pathPoints.dropFirst().first ?? end)
        head(endHead,at:end,awayFrom:pathPoints.dropLast().last ?? start)
    }
    static func drawArrowComment(_ item:CaptureAnnotation,in ctx:CGContext) {
        guard let rect=item.arrowCommentRect else{return}
        let color=item.color.usingColorSpace(.deviceRGB) ?? .red
        let luminance=0.2126*color.redComponent+0.7152*color.greenComponent+0.0722*color.blueComponent
        ctx.setFillColor((luminance>0.65 ? NSColor.black.withAlphaComponent(0.85) : NSColor.white.withAlphaComponent(0.92)).cgColor)
        ctx.fill(rect.insetBy(dx:-4,dy:-3))
        NSGraphicsContext.saveGraphicsState();defer{NSGraphicsContext.restoreGraphicsState()}
        NSGraphicsContext.current=NSGraphicsContext(cgContext:ctx,flipped:false)
        (item.options.arrowComment as NSString).draw(with:rect,options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:item.arrowCommentFont,.foregroundColor:color])
    }
    static func drawNumber(_ item:CaptureAnnotation,in ctx:CGContext) {
        guard let first=item.points.first,let last=item.points.last else{return}
        let fontSize=max(18,item.width*6),radius=item.numberRadius
        let distance=hypot(last.x-first.x,last.y-first.y)
        if item.options.numberLeader,distance > radius+4 {
            let edge=CGPoint(x:first.x+(last.x-first.x)*radius/distance,y:first.y+(last.y-first.y)*radius/distance)
            styledLine(from:edge,to:last,item:item,in:ctx,endHead:item.options.arrowEnd)
        }
        let badge=CGRect(x:first.x-radius,y:first.y-radius,width:radius*2,height:radius*2)
        if item.options.numberShape == .circle {
            if item.options.numberFilled {ctx.fillEllipse(in:badge)} else {ctx.strokeEllipse(in:badge)}
        } else {
            if item.options.numberFilled {ctx.fill(badge)} else {ctx.stroke(badge)}
        }
        NSGraphicsContext.saveGraphicsState();defer{NSGraphicsContext.restoreGraphicsState()}
        NSGraphicsContext.current=NSGraphicsContext(cgContext:ctx,flipped:false)
        let color=item.options.numberFilled ? NSColor.white : item.color
        let attributes:[NSAttributedString.Key:Any]=[.font:NSFont.boldSystemFont(ofSize:fontSize),.foregroundColor:color]
        let text=item.numberLabel as NSString,size=text.size(withAttributes:attributes)
        text.draw(at:CGPoint(x:first.x-size.width/2,y:first.y-size.height/2),withAttributes:attributes)
    }
}
