import AppKit
import Foundation

public struct CapturePinText:Codable,Sendable,Equatable {
    public var plain:String
    public var html:String?
    public var rtf:Data?
    public var ignoreFormatting=false
    public var fontName="Menlo"
    public var fontSize=18.0
    public var foreground=[0.0,0,0,1]
    public var background=[1.0,1,1,1]
    public init(plain:String,html:String? = nil,rtf:Data? = nil) { self.plain=plain;self.html=html;self.rtf=rtf }
    public var valid:Bool {
        plain.utf8.count <= 1024*1024 && (html?.utf8.count ?? 0) <= 2*1024*1024 && (rtf?.count ?? 0) <= 4*1024*1024 && (rtf.map { $0.starts(with:Data("{\\rtf".utf8)) } ?? true) &&
        fontName.count <= 100 && fontSize.isFinite && (8...96).contains(fontSize) && Self.validRGBA(foreground) && Self.validRGBA(background)
    }
    public static func validRGBA(_ rgba:[Double]) -> Bool { rgba.count == 4 && rgba.allSatisfy { $0.isFinite && (0...1).contains($0) } }
    public var usesHTML:Bool { !ignoreFormatting && rtf == nil && html != nil }
    public func attributed() throws -> NSAttributedString {
        guard valid else { throw CapturePinFailure.invalidLibrary }
        if !ignoreFormatting,let rtf {
            guard rtf.starts(with:Data("{\\rtf".utf8)) else { throw CapturePinFailure.invalidLibrary }
            let result=try NSMutableAttributedString(data:rtf,options:[.documentType:NSAttributedString.DocumentType.rtf],documentAttributes:nil)
            guard result.length <= 1024*1024 else { throw CapturePinFailure.invalidLibrary }
            // Rendering rich text never resolves links or external attachments.
            result.removeAttribute(.attachment,range:NSRange(location:0,length:result.length));result.removeAttribute(.link,range:NSRange(location:0,length:result.length))
            return result
        }
        return NSAttributedString(string:plain,attributes:[.font:NSFont(name:fontName,size:fontSize) ?? .monospacedSystemFont(ofSize:fontSize,weight:.regular),.foregroundColor:Self.color(foreground)])
    }
    public static func color(_ rgba:[Double]) -> NSColor { NSColor(deviceRed:rgba[0],green:rgba[1],blue:rgba[2],alpha:rgba[3]) }
    /// Only WebKit renders HTML. Both CSP and the host view forbid script/navigation/network access.
    public var isolatedHTML:String {
        "<!doctype html><html><head><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'\"><style>body{overflow-wrap:anywhere;margin:16px;color:#111;background:#fff}</style></head><body>"+(html ?? "")+"</body></html>"
    }
}

public struct CapturePinFile:Codable,Sendable,Equatable,Identifiable {
    public var id=UUID()
    public let path:String
    public let bookmark:Data?
    public init(url:URL) throws {
        guard url.isFileURL,(url.host == nil || url.host == "" || url.host == "localhost"),!url.path.contains("\0"),url.path.utf8.count <= 16384 else { throw CapturePinFailure.invalidLibrary }
        path=url.standardizedFileURL.path
        bookmark=try? url.bookmarkData(options:.minimalBookmark,includingResourceValuesForKeys:nil,relativeTo:nil)
    }
    public var valid:Bool { path.hasPrefix("/") && !path.contains("\0") && path.utf8.count <= 16384 && (bookmark?.count ?? 0) <= 1024*1024 }
    public func resolved() throws -> URL {
        guard valid else { throw CapturePinFailure.invalidLibrary }
        if let bookmark {
            var stale=false
            if let url=try? URL(resolvingBookmarkData:bookmark,options:[.withoutUI,.withoutMounting],relativeTo:nil,bookmarkDataIsStale:&stale),url.isFileURL { return url }
        }
        return URL(fileURLWithPath:path)
    }
}

public struct CapturePinColor:Codable,Sendable,Equatable {
    public var red:Int
    public var green:Int
    public var blue:Int
    public var alpha:Double
    public init(red:Int,green:Int,blue:Int,alpha:Double=1) { self.red=red;self.green=green;self.blue=blue;self.alpha=alpha }
    public var valid:Bool { (0...255).contains(red) && (0...255).contains(green) && (0...255).contains(blue) && alpha.isFinite && (0...1).contains(alpha) }
    public var nsColor:NSColor { NSColor(srgbRed:Double(red)/255,green:Double(green)/255,blue:Double(blue)/255,alpha:alpha) }
    public enum Format:String,CaseIterable,Codable,Sendable { case hex="HEX",rgb="RGB",rgba="RGBA",hsl="HSL",hsv="HSV" }
    public func formatted(_ format:Format) -> String {
        switch format {
        case .hex:return String(format:alpha < 1 ? "#%02X%02X%02X%02X" : "#%02X%02X%02X",red,green,blue,Int((alpha*255).rounded()))
        case .rgb:return "rgb(\(red), \(green), \(blue))"
        case .rgba:return String(format:"rgba(%d, %d, %d, %.3g)",locale:Locale(identifier:"en_US_POSIX"),red,green,blue,alpha)
        case .hsl,.hsv:
            let r=Double(red)/255,g=Double(green)/255,b=Double(blue)/255,hi=max(r,g,b),lo=min(r,g,b),d=hi-lo,l=(hi+lo)/2
            var h=0.0
            if d > 0 { if hi == r { h=(g-b)/d };if hi == g { h=(b-r)/d+2 };if hi == b { h=(r-g)/d+4 };h=(h*60+360).truncatingRemainder(dividingBy:360) }
            let saturation=format == .hsv ? (hi == 0 ? 0 : d/hi) : (d == 0 ? 0 : d/(1-abs(2*l-1)))
            return String(format:"%@(%g, %.1f%%, %.1f%%)",locale:Locale(identifier:"en_US_POSIX"),format.rawValue.lowercased(),h.rounded(),saturation*100,(format == .hsv ? hi : l)*100)
        }
    }
    public static func parse(_ input:String) -> Self? {
        let value=input.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        if value.first == "#" {
            let chars=String(value.dropFirst())
            guard [3,4,6,8].contains(chars.count),chars.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
            let expanded=chars.count <= 4 ? chars.map { "\($0)\($0)" }.joined() : chars
            let pairs=stride(from:0,to:expanded.count,by:2).map { offset -> Int in let start=expanded.index(expanded.startIndex,offsetBy:offset);return Int(expanded[start..<expanded.index(start,offsetBy:2)],radix:16)! }
            return .init(red:pairs[0],green:pairs[1],blue:pairs[2],alpha:pairs.count == 4 ? Double(pairs[3])/255 : 1)
        }
        if let named=named[value] { return named }
        var source=value
        for prefix in ["rgba(","rgb(","hsla(","hsl(","hsva(","hsv("] where source.hasPrefix(prefix) && source.hasSuffix(")") { source=String(source.dropFirst(prefix.count).dropLast());break }
        let parts=source.split(separator:",",omittingEmptySubsequences:false).map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }
        guard parts.count == 3 || parts.count == 4 else { return nil }
        func number(_ string:String,scale:Double) -> Double? { let percent=string.hasSuffix("%"),raw=percent ? String(string.dropLast()) : string;guard let n=Double(raw),n.isFinite else { return nil };return percent ? n/100*scale : n }
        guard let a=parts.count == 4 ? number(parts[3],scale:1) : 1,(0...1).contains(a) else { return nil }
        if value.hasPrefix("hsl(") || value.hasPrefix("hsla(") || value.hasPrefix("hsv(") || value.hasPrefix("hsva(") {
            guard let h=Double(parts[0]),h.isFinite,parts[1].hasSuffix("%"),parts[2].hasSuffix("%"),let s=number(parts[1],scale:1),let l=number(parts[2],scale:1),(0...1).contains(s),(0...1).contains(l) else { return nil }
            let hue=(h.truncatingRemainder(dividingBy:360)+360).truncatingRemainder(dividingBy:360)/60
            let c=value.hasPrefix("hsv") ? l*s : (1-abs(2*l-1))*s,x=c*(1-abs(hue.truncatingRemainder(dividingBy:2)-1)),m=l-(value.hasPrefix("hsv") ? c : c/2)
            let triple:(Double,Double,Double)
            switch hue { case ..<1:triple=(c,x,0);case ..<2:triple=(x,c,0);case ..<3:triple=(0,c,x);case ..<4:triple=(0,x,c);case ..<5:triple=(x,0,c);default:triple=(c,0,x) }
            return .init(red:Int(((triple.0+m)*255).rounded()),green:Int(((triple.1+m)*255).rounded()),blue:Int(((triple.2+m)*255).rounded()),alpha:a)
        }
        // An unknown function must not be mistaken for bare RGB values.
        guard !value.contains("(") || value.hasPrefix("rgb(") || value.hasPrefix("rgba(") else { return nil }
        guard let r=number(parts[0],scale:255),let g=number(parts[1],scale:255),let b=number(parts[2],scale:255),[r,g,b].allSatisfy({ (0...255).contains($0) }) else { return nil }
        return .init(red:Int(r.rounded()),green:Int(g.rounded()),blue:Int(b.rounded()),alpha:a)
    }
    private static let named:[String:Self] = {
        var result=cssNamedRGB.mapValues { Self(red:Int(($0 >> 16)&255),green:Int(($0 >> 8)&255),blue:Int($0&255)) }
        result["transparent"] = .init(red:0,green:0,blue:0,alpha:0);return result
    }()

}

public enum CapturePinContent:Codable,Sendable,Equatable {
    case text(CapturePinText),files([CapturePinFile]),color(CapturePinColor),latex(CaptureLaTeX)
    public var valid:Bool {
        switch self { case .text(let value):return value.valid;case .files(let values):return !values.isEmpty && values.count <= 100 && values.allSatisfy(\.valid);case .color(let value):return value.valid;case .latex(let value):return value.valid }
    }
    public var kind:String { switch self { case .text:return "text";case .files:return "files";case .color:return "color";case .latex:return "latex" } }
    public func previewImage() throws -> CGImage {
        guard valid else { throw CapturePinFailure.invalidLibrary }
        let text:NSAttributedString,background:NSColor,swatch:NSColor?
        switch self {
        case .latex(let formula):return try formula.render().image
        case .text(let value):text=try value.attributed();background=CapturePinText.color(value.background);swatch=nil
        case .files(let files):text=NSAttributedString(string:files.map(\.path).joined(separator:"\n\n"),attributes:[.font:NSFont.systemFont(ofSize:18),.foregroundColor:NSColor.black]);background = .white;swatch=nil
        case .color(let color):text=NSAttributedString(string:CapturePinColor.Format.allCases.map { color.formatted($0) }.joined(separator:"\n"),attributes:[.font:NSFont.monospacedSystemFont(ofSize:20,weight:.regular),.foregroundColor:NSColor.black]);background = .white;swatch=color.nsColor
        }
        let size=text.boundingRect(with:CGSize(width:640,height:8192),options:[.usesLineFragmentOrigin,.usesFontLeading]).size
        let width=Int(max(240,min(672,ceil(size.width)+32))),height=Int(max(80,min(8192,ceil(size.height)+32+(swatch == nil ? 0 : 150))))
        guard let ctx=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureFailure.invalidImage }
        ctx.setFillColor(background.cgColor);ctx.fill(CGRect(x:0,y:0,width:width,height:height))
        if let swatch { ctx.setFillColor(swatch.cgColor);ctx.fill(CGRect(x:16,y:height-134,width:width-32,height:118)) }
        NSGraphicsContext.saveGraphicsState();defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current=NSGraphicsContext(cgContext:ctx,flipped:false)
        text.draw(with:CGRect(x:16,y:16,width:width-32,height:height-32-(swatch == nil ? 0 : 150)),options:[.usesLineFragmentOrigin,.usesFontLeading])
        guard let result=ctx.makeImage() else { throw CaptureFailure.invalidImage };return result
    }
}
