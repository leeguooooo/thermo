import AppKit
import Foundation
import JavaScriptCore

public struct CaptureLaTeX:Codable,Sendable,Equatable {
    public var source:String
    public var display=true
    public var fontSize=32.0
    public var foreground="#000000"
    public var background="#FFFFFF"
    public var transparentBackground=true
    public init(source:String,display:Bool=true) { self.source=source;self.display=display }
    public var valid:Bool { !expression.isEmpty && source.utf8.count <= 16384 && fontSize.isFinite && (8...96).contains(fontSize) && CapturePinLibrary.validColor(foreground) && CapturePinLibrary.validColor(background) }
    public var expression:String {
        let value=source.trimmingCharacters(in:.whitespacesAndNewlines)
        for (a,b) in [("$$","$$"),("\\[","\\]"),("\\(","\\)"),("$","$")] where value.hasPrefix(a) && value.hasSuffix(b) && value.count >= a.count+b.count {
            return String(value.dropFirst(a.count).dropLast(b.count)).trimmingCharacters(in:.whitespacesAndNewlines)
        }
        return value
    }
    public static func detect(_ source:String) -> Self? {
        let value=source.trimmingCharacters(in:.whitespacesAndNewlines)
        var display:Bool?
        if (value.hasPrefix("$$") && value.hasSuffix("$$")) || (value.hasPrefix("\\[") && value.hasSuffix("\\]")) { display=true }
        else if (value.hasPrefix("\\(") && value.hasSuffix("\\)")) || (value.hasPrefix("$") && value.hasSuffix("$") && unescapedDollars(value) == 2) { display=false }
        else if value.hasPrefix("\\") {
            let command=String(value.dropFirst().prefix { $0.isASCII && $0.isLetter })
            let names:Set<String>=["frac","dfrac","tfrac","sqrt","begin","int","iint","iiint","oint","sum","prod","lim","left","alpha","beta","gamma","delta","epsilon","varepsilon","zeta","eta","theta","vartheta","iota","kappa","lambda","mu","nu","xi","pi","varpi","rho","varrho","sigma","varsigma","tau","upsilon","phi","varphi","chi","psi","omega","Gamma","Delta","Theta","Lambda","Xi","Pi","Sigma","Upsilon","Phi","Psi","Omega","partial","nabla","infty","mathbb","mathbf","mathrm","mathcal","mathfrak","text","ce","sin","cos","tan","log","ln","exp","operatorname","overline","hat","dot","vec","boxed","newcommand"]
            if names.contains(command) { display=true }
        }
        guard let display else { return nil };let result=Self(source:source,display:display);return result.valid ? result : nil
    }
    private static func unescapedDollars(_ value:String) -> Int {
        var escaped=false,count=0
        for char in value { if char == "\\" { escaped.toggle();continue };if char == "$" && !escaped { count += 1 };escaped=false }
        return count
    }
    public func render() throws -> CaptureMathResult { try CaptureMathRenderer.shared.render(self) }
}
public struct CaptureMathResult {
    public let svg:String
    public let mathml:String
    public let image:CGImage
    public let logicalSize:CGSize
}
public enum CaptureMathFailure:LocalizedError {
    case missingRenderer,invalidFormula(String),invalidOutput
    public var errorDescription:String? {
        switch self {
        case .missingRenderer:return "The local math renderer is missing from this app."
        case .invalidFormula(let reason):return "Formula could not be rendered: "+reason
        case .invalidOutput:return "The formula renderer produced an invalid image."
        }
    }
}
private final class CaptureMathRenderer {
    static let shared=CaptureMathRenderer()
    private let lock=NSLock()
    private var last:CaptureLaTeX?
    private var result:CaptureMathResult?
    private var script:String?
    func render(_ formula:CaptureLaTeX) throws -> CaptureMathResult {
        guard formula.valid else { throw CapturePinFailure.invalidContent }
        lock.lock();defer { lock.unlock() }
        if last == formula,let result { return result }
        let source:String
        if let script { source=script }
        else {
            var urls:[URL]=[]
            if let resource=Bundle.main.resourceURL { urls.append(resource.appendingPathComponent("CaptureMath/mathjax-4.1.3.bundle.js")) }
            #if DEBUG
            let repo=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            urls.append(repo.appendingPathComponent("Resources/CaptureMath/mathjax-4.1.3.bundle.js"))
            #endif
            guard let url=urls.first(where:{ FileManager.default.fileExists(atPath:$0.path) }),let value=try? String(contentsOf:url,encoding:.utf8) else { throw CaptureMathFailure.missingRenderer }
            source=value;script=value
        }
        // JavaScriptCore receives no host/network/file callbacks. Source is passed as data.
        guard let context=JSContext() else { throw CaptureMathFailure.missingRenderer }
        context.evaluateScript(source)
        guard context.exception == nil,let engine=context.objectForKeyedSubscript("ThermoMath"),
              let json=engine.invokeMethod("renderJSON",withArguments:[formula.expression,formula.display,formula.fontSize,formula.foreground])?.toString(),let bytes=json.data(using:.utf8),bytes.count <= 20*1024*1024,
              let object=try JSONSerialization.jsonObject(with:bytes) as? [String:Any] else { throw CaptureMathFailure.invalidOutput }
        if let error=object["error"] as? String { throw CaptureMathFailure.invalidFormula(String(error.prefix(2000))) }
        guard var svg=object["svg"] as? String,let mathml=object["mathml"] as? String,let width=object["width"] as? Int,let height=object["height"] as? Int,
              width > 0,height > 0,width <= 8192,height <= 8192,width <= 16000000/height else { throw CaptureMathFailure.invalidOutput }
        if !formula.transparentBackground {
            guard let end=svg.firstIndex(of:">") else { throw CaptureMathFailure.invalidOutput }
            // A viewBox-covering rect uses user-controlled color only after strict HEX validation.
            if let range=svg.range(of:"viewBox=\""),let close=svg[range.upperBound...].firstIndex(of:"\"") {
                let box=svg[range.upperBound..<close].split(separator:" ").compactMap { Double($0) }
                guard box.count == 4 else { throw CaptureMathFailure.invalidOutput }
                svg.insert(contentsOf:"<rect x=\"\(box[0])\" y=\"\(box[1])\" width=\"\(box[2])\" height=\"\(box[3])\" fill=\"\(formula.background)\"/>",at:svg.index(after:end))
            } else { throw CaptureMathFailure.invalidOutput }
        }
        try CaptureMathXML.validateSVG(svg)
        guard mathml.utf8.count <= 4*1024*1024,mathml.hasPrefix("<math "),!mathml.localizedCaseInsensitiveContains("<!DOCTYPE"),let image=NSImage(data:Data(svg.utf8)),
              let ctx=CGContext(data:nil,width:width*2,height:height*2,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureMathFailure.invalidOutput }
        ctx.clear(CGRect(x:0,y:0,width:width*2,height:height*2));ctx.scaleBy(x:2,y:2)
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:ctx,flipped:false)
        image.draw(in:CGRect(x:0,y:0,width:width,height:height),from:.zero,operation:.copy,fraction:1)
        NSGraphicsContext.restoreGraphicsState()
        guard let cg=ctx.makeImage() else { throw CaptureMathFailure.invalidOutput }
        let value=CaptureMathResult(svg:svg,mathml:mathml,image:cg,logicalSize:CGSize(width:width,height:height))
        last=formula;result=value;return value
    }
}
private final class CaptureMathXML:NSObject,XMLParserDelegate {
    private var valid=true
    private static let elements:Set<String>=["svg","g","path","rect","line","polyline","polygon","circle","ellipse","text","tspan","defs","clipPath","title","desc"]
    private static let attributes:Set<String>=["xmlns","xmlns:xlink","width","height","viewBox","role","focusable","style","stroke","fill","stroke-width","transform","d","data-c","data-mml-node","data-mjx-texclass","x","y","x1","x2","y1","y2","cx","cy","r","rx","ry","points","opacity","fill-opacity","stroke-opacity","stroke-linecap","stroke-linejoin","stroke-miterlimit","font-family","font-size","font-style","font-weight","font-variant","text-anchor","dominant-baseline","aria-hidden","aria-label","id","clip-path"]
    static func validateSVG(_ string:String) throws {
        guard string.utf8.count <= 16*1024*1024,!string.localizedCaseInsensitiveContains("<!DOCTYPE"),!string.localizedCaseInsensitiveContains("<!ENTITY") else { throw CaptureMathFailure.invalidOutput }
        let parser=XMLParser(data:Data(string.utf8)),delegate=CaptureMathXML();parser.delegate=delegate;parser.shouldResolveExternalEntities=false;parser.externalEntityResolvingPolicy = .never
        guard parser.parse(),delegate.valid else { throw CaptureMathFailure.invalidOutput }
    }
    func parser(_ parser:XMLParser,didStartElement name:String,namespaceURI:String?,qualifiedName:String?,attributes:[String:String]) {
        guard Self.elements.contains(name) else { valid=false;parser.abortParsing();return }
        for (key,value) in attributes {
            let lower=value.lowercased()
            guard (Self.attributes.contains(key) || key.hasPrefix("data-")),!lower.contains("javascript:"),!lower.contains("@import"),!lower.contains("expression("),(!lower.contains("url(") || lower.range(of:"^url\\(#[A-Za-z0-9_.:-]+\\)$",options:.regularExpression) != nil) else { valid=false;parser.abortParsing();return }
        }
    }
}
