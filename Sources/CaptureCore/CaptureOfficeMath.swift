import Foundation

public enum CaptureWordFailure:LocalizedError {
    case invalidMath,unsupported(String),missingTemplate,packageFailed,wordNotInstalled
    public var errorDescription:String? {
        switch self {
        case .wordNotInstalled:return "Microsoft Word is not installed on this Mac."
        case .invalidMath:return "The formula could not be converted to editable Word math."
        case .unsupported(let item):return "Word math export does not support: "+item
        case .missingTemplate:return "The editable Word template is missing from this app."
        case .packageFailed:return "The editable Word document could not be created."
        }
    }
}

/// Converts Presentation MathML to native Office Math objects, never pictures.
public enum CaptureOfficeMath {
    public static let namespace="http://schemas.openxmlformats.org/officeDocument/2006/math"
    public static func convert(_ mathml:String,formula:CaptureLaTeX) throws -> String {
        guard formula.valid else { throw CaptureWordFailure.invalidMath }
        let root=try MathTree.parse(mathml)
        let context=OfficeContext(color:String(formula.foreground.dropFirst()),size:formula.fontSize,display:formula.display)
        let body=try OfficeConverter().element(root,context)
        let math="<m:oMath xmlns:m=\"\(namespace)\" xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">\(body)</m:oMath>"
        return formula.display ? "<m:oMathPara xmlns:m=\"\(namespace)\"><m:oMathParaPr><m:jc m:val=\"center\"/></m:oMathParaPr>\(math)</m:oMathPara>" : math
    }
}
private final class MathNode {
    let name:String
    let attributes:[String:String]
    var children:[MathNode]=[]
    var text=""
    init(_ name:String,_ attributes:[String:String]) { self.name=name;self.attributes=attributes }
    var string:String { text+children.map(\.string).joined() }
}
private final class MathTree:NSObject,XMLParserDelegate {
    private var stack:[MathNode]=[]
    private var root:MathNode?
    private var nodes=0
    private var valid=true
    static func parse(_ xml:String) throws -> MathNode {
        guard xml.utf8.count <= 4*1024*1024,!xml.localizedCaseInsensitiveContains("<!DOCTYPE"),!xml.localizedCaseInsensitiveContains("<!ENTITY") else { throw CaptureWordFailure.invalidMath }
        let parser=XMLParser(data:Data(xml.utf8)),tree=MathTree();parser.delegate=tree;parser.shouldProcessNamespaces=true;parser.shouldResolveExternalEntities=false;parser.externalEntityResolvingPolicy = .never
        guard parser.parse(),tree.valid,tree.stack.isEmpty,let root=tree.root,root.name == "math" else { throw CaptureWordFailure.invalidMath };return root
    }
    func parser(_ parser:XMLParser,didStartElement name:String,namespaceURI:String?,qualifiedName:String?,attributes:[String:String]) {
        nodes += 1
        guard nodes <= 100000,stack.count < 256,namespaceURI == "http://www.w3.org/1998/Math/MathML" else { valid=false;parser.abortParsing();return }
        let node=MathNode(name,attributes)
        if let parent=stack.last { parent.children.append(node) } else if root == nil { root=node } else { valid=false;parser.abortParsing();return };stack.append(node)
    }
    func parser(_ parser:XMLParser,foundCharacters text:String) { stack.last?.text += text }
    func parser(_ parser:XMLParser,didEndElement name:String,namespaceURI:String?,qualifiedName:String?) { _=stack.popLast() }
}
private struct OfficeContext {
    var color:String
    var size:Double
    var display:Bool
    var variant:String?
    var shading:String?
}
private func officeXML(_ text:String) -> String { text.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;").replacingOccurrences(of:"'",with:"&apos;") }
private final class OfficeConverter {
    private let nary:Set<String>=["∑","∏","∐","∫","∬","∭","∮","∯","∰","⋂","⋃","⋀","⋁","⨀","⨁","⨂"]
    private let scriptNames:Set<String>=["msub","msup","msubsup","munder","mover","munderover"]
    private let fences:[String:String]=["(":")","[":"]","{":"}","|":"|","‖":"‖","⟨":"⟩","⌈":"⌉","⌊":"⌋","⟦":"⟧"]
    private func context(_ node:MathNode,_ input:OfficeContext) throws -> OfficeContext {
        var c=input
        if let value=node.attributes["mathvariant"] { c.variant=value }
        if let value=node.attributes["displaystyle"] { c.display=value == "true" }
        for (key,isBackground) in [("mathcolor",false),("mathbackground",true)] {
            if let value=node.attributes[key],value != "transparent" {
                guard let color=CapturePinColor.parse(value) else { throw CaptureWordFailure.unsupported(key+"="+value) }
                if isBackground { c.shading=String(color.formatted(.hex).dropFirst().prefix(6)) } else { c.color=String(color.formatted(.hex).dropFirst().prefix(6)) }
            }
        }
        if let value=node.attributes["mathsize"] {
            if value == "small" { c.size *= 0.8 } else if value == "big" { c.size *= 1.2 } else if value != "normal" {
                if value.hasSuffix("em"),let n=Double(value.dropLast(2)),n.isFinite,n > 0,n <= 10 { c.size *= n }
                else if value.hasSuffix("px"),let n=Double(value.dropLast(2)),n.isFinite,n > 0,n <= 960 { c.size=n }
                else { throw CaptureWordFailure.unsupported("mathsize="+value) }
            }
        }
        guard c.size.isFinite,c.size >= 1,c.size <= 960 else { throw CaptureWordFailure.unsupported("math size") };return c
    }
    private func wordProperties(_ c:OfficeContext) -> String {
        let shading=c.shading.map { "<w:shd w:val=\"clear\" w:fill=\"\($0)\"/>" } ?? ""
        return "<w:rPr><w:rFonts w:ascii=\"Cambria Math\" w:hAnsi=\"Cambria Math\"/><w:color w:val=\"\(c.color)\"/><w:sz w:val=\"\(Int((c.size*2).rounded()))\"/>\(shading)</w:rPr>"
    }
    private func control(_ c:OfficeContext) -> String { "<m:ctrlPr>\(wordProperties(c))</m:ctrlPr>" }
    private func run(_ text:String,_ c:OfficeContext,plain:Bool=false) throws -> String {
        if text.isEmpty { return "" }
        let variant=c.variant ?? (plain ? "normal" : "italic")
        let styles:[String:(String,String?)]=["normal":("p",nil),"bold":("b",nil),"italic":("i",nil),"bold-italic":("bi",nil),"double-struck":("p","double-struck"),"script":("p","script"),"bold-script":("b","script"),"fraktur":("p","fraktur"),"bold-fraktur":("b","fraktur"),"sans-serif":("p","sans-serif"),"bold-sans-serif":("b","sans-serif"),"sans-serif-italic":("i","sans-serif"),"sans-serif-bold-italic":("bi","sans-serif"),"monospace":("p","monospace")]
        guard let (style,script)=styles[variant] else { throw CaptureWordFailure.unsupported("mathvariant="+variant) }
        let scr=script.map { "<m:scr m:val=\"\($0)\"/>" } ?? ""
        return "<m:r><m:rPr>\(scr)<m:sty m:val=\"\(style)\"/></m:rPr>\(wordProperties(c))<m:t xml:space=\"preserve\">\(officeXML(text))</m:t></m:r>"
    }
    private func wrap(_ name:String,_ content:String) -> String { "<m:\(name)>\(content)</m:\(name)>" }
    private func require(_ node:MathNode,_ count:Int) throws { guard node.children.count == count else { throw CaptureWordFailure.invalidMath } }
    private func base(_ node:MathNode) -> MathNode { scriptNames.contains(node.name) && !node.children.isEmpty ? node.children[0] : node }
    private func isNary(_ node:MathNode) -> Bool { let b=base(node);return b.name == "mo" && nary.contains(b.string) }
    func sequence(_ nodes:[MathNode],_ c:OfficeContext) throws -> String {
        var result="",i=0
        while i < nodes.count {
            let node=nodes[i]
            // mhchem's layout-only phantom scripts become native pre/post scripts.
            if node.name == "mspace",node.attributes["width"]?.hasPrefix("-") == true,
               (i > 0 && isVirtualScript(nodes[i-1]) || i+1 < nodes.count && isVirtualScript(nodes[i+1])) { i += 1;continue }
            if i+1 < nodes.count,isVirtualScript(nodes[i+1]) {
                let scripts=visibleScripts(nodes[i+1]);result += try element(scriptNode(base:node,sub:scripts.0,sup:scripts.1),c);i += 2;continue
            }
            if isVirtualScript(node) {
                let scripts=visibleScripts(node)
                if scripts.0 == nil && scripts.1 == nil { i += 1;continue }
                var next=i+1
                while next < nodes.count && nodes[next].name == "mspace" && nodes[next].attributes["width"]?.hasPrefix("-") == true { next += 1 }
                guard next < nodes.count else { throw CaptureWordFailure.unsupported("detached chemistry script") }
                let pre=MathNode("mmultiscripts",[:]);pre.children=[nodes[next],MathNode("mprescripts",[:]),scripts.0 ?? MathNode("none",[:]),scripts.1 ?? MathNode("none",[:])]
                result += try element(pre,c);i=next+1;continue
            }
            if isNary(node) {
                var next=i+1,body=""
                while next < nodes.count && nodes[next].name == "mspace" { body += try element(nodes[next],c);next += 1 }
                if next < nodes.count,!(nodes[next].name == "mo" && ["+","−","=",",",";", ")","]","}"].contains(nodes[next].string)) { body += try element(nodes[next],c);next += 1 }
                result += try largeOperator(node,body:body,context:context(node,c));i=next;continue
            }
            if i+2 < nodes.count,nodes[i+1].name == "mo",nodes[i+1].string == "\u{2061}" {
                result += "<m:func><m:funcPr>\(control(c))</m:funcPr><m:fName>\(try element(node,c))</m:fName><m:e>\(try element(nodes[i+2],c))</m:e></m:func>";i += 3;continue
            }
            result += try element(node,c);i += 1
        }
        return result
    }
    func element(_ node:MathNode,_ parent:OfficeContext) throws -> String {
        let c=try context(node,parent),kids=node.children
        if !["mi","mn","mo","mtext","ms","annotation"].contains(node.name),!node.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { throw CaptureWordFailure.invalidMath }
        switch node.name {
        case "math","mstyle","mtd":return try sequence(kids,c)
        case "mrow":
            if let first=kids.first,let last=kids.last,kids.count >= 2,first.name == "mo",let close=fences[first.string],last.name == "mo",last.string == close {
                return try delimiter(first.string,close,[Array(kids.dropFirst().dropLast())],c)
            }
            if kids.count == 2,kids[0].name == "mo",kids[0].string == "{",kids[1].name == "mtable" { return try delimiter("{","",[[kids[1]]],c) }
            return try sequence(kids,c)
        case "semantics":guard let first=kids.first else { throw CaptureWordFailure.invalidMath };return try element(first,c)
        case "annotation","annotation-xml":return ""
        case "mi":guard kids.isEmpty else { throw CaptureWordFailure.invalidMath };return try run(node.string,c,plain:node.string.count != 1)
        case "mn","mtext","ms":guard kids.isEmpty else { throw CaptureWordFailure.invalidMath };return try run(node.name == "ms" ? (node.attributes["lquote"] ?? "\"")+node.string+(node.attributes["rquote"] ?? "\"") : node.string,c,plain:true)
        case "mo":guard kids.isEmpty else { throw CaptureWordFailure.invalidMath };if isNary(node) { return try largeOperator(node,body:"",context:c) };return try run(node.string == "\u{2061}" ? "" : node.string,c,plain:true)
        case "mspace":return try spacing(node,c)
        case "mfrac":
            try require(node,2);let type=node.attributes["bevelled"] == "true" ? "skw" : (["0","0px","0em"].contains(node.attributes["linethickness"] ?? "") ? "noBar" : "bar")
            return "<m:f><m:fPr><m:type m:val=\"\(type)\"/>\(control(c))</m:fPr><m:num>\(try element(kids[0],c))</m:num><m:den>\(try element(kids[1],c))</m:den></m:f>"
        case "msqrt","mroot":
            if node.name == "mroot" { try require(node,2) }
            let degree=node.name == "mroot" ? try element(kids[1],c) : "",body=node.name == "mroot" ? try element(kids[0],c) : try sequence(kids,c)
            return "<m:rad><m:radPr><m:degHide m:val=\"\(node.name == "msqrt" ? 1 : 0)\"/>\(control(c))</m:radPr><m:deg>\(degree)</m:deg><m:e>\(body)</m:e></m:rad>"
        case "msub","msup","msubsup":
            try require(node,node.name == "msubsup" ? 3 : 2)
            if isNary(node) { return try largeOperator(node,body:"",context:c) }
            let tag=node.name == "msub" ? "sSub" : (node.name == "msup" ? "sSup" : "sSubSup")
            let sub=node.name == "msup" ? "" : wrap("sub",try element(kids[1],c)),sup=node.name == "msub" ? "" : wrap("sup",try element(kids[node.name == "msup" ? 1 : 2],c))
            return "<m:\(tag)><m:\(tag)Pr>\(control(c))</m:\(tag)Pr><m:e>\(try element(kids[0],c))</m:e>\(sub)\(sup)</m:\(tag)>"
        case "munder","mover","munderover":
            try require(node,node.name == "munderover" ? 3 : 2)
            if isNary(node) { return try largeOperator(node,body:"",context:c) }
            if node.name != "munderover" { return try limit(node.name == "mover",base:element(kids[0],c),script:kids[1],accent:isAccent(node,over:node.name == "mover"),context:c) }
            let low=try limit(false,base:element(kids[0],c),script:kids[1],accent:isAccent(node,over:false),context:c)
            return try limit(true,base:low,script:kids[2],accent:isAccent(node,over:true),context:c)
        case "mfenced":
            let separators=Array(node.attributes["separators"] ?? ",").filter { !$0.isWhitespace }
            if separators.count > 1 { throw CaptureWordFailure.unsupported("mixed fence separators") }
            return try delimiter(node.attributes["open"] ?? "(",node.attributes["close"] ?? ")",kids.map { [$0] },c,separator:separators.first.map(String.init) ?? "")
        case "mtable":return try table(node,c)
        case "mphantom":return "<m:phant><m:phantPr><m:show m:val=\"0\"/>\(control(c))</m:phantPr><m:e>\(try sequence(kids,c))</m:e></m:phant>"
        case "mpadded":
            for key in ["width","height","depth","lspace"] { if let value=node.attributes[key],!["0","0em","0px"].contains(value) { throw CaptureWordFailure.unsupported("mpadded "+key+"="+value) } }
            // Office's box preserves visible content. It has no MathML metric overrides.
            return "<m:box><m:boxPr>\(control(c))</m:boxPr><m:e>\(try sequence(kids,c))</m:e></m:box>"
        case "menclose":return try enclosure(node,c)
        case "mmultiscripts":return try multiscripts(node,c)
        case "none":return ""
        default:throw CaptureWordFailure.unsupported(node.name)
        }
    }
    private func isVirtualScript(_ node:MathNode) -> Bool { ["msub","msup","msubsup"].contains(node.name) && node.children.count == (node.name == "msubsup" ? 3 : 2) && node.children.first.map(isZeroPhantom) == true }
    private func visibleScripts(_ node:MathNode) -> (MathNode?,MathNode?) {
        let sub=node.name == "msup" ? nil : visible(node.children[1])
        let sup=node.name == "msub" ? nil : visible(node.children[node.name == "msup" ? 1 : 2])
        return (sub,sup)
    }
    private func visible(_ node:MathNode) -> MathNode? {
        if node.name == "mphantom" { return nil }
        let copy=MathNode(node.name == "mpadded" ? "mrow" : node.name,node.attributes);copy.text=node.text;copy.children=node.children.compactMap(visible)
        return copy.children.isEmpty && copy.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? nil : copy
    }
    private func scriptNode(base:MathNode,sub:MathNode?,sup:MathNode?) -> MathNode {
        guard sub != nil || sup != nil else { return base }
        let node=MathNode(sub == nil ? "msup" : (sup == nil ? "msub" : "msubsup"),[:]);node.children=[base]+[sub,sup].compactMap { $0 };return node
    }
    private func isZeroPhantom(_ node:MathNode) -> Bool {
        if node.name == "mpadded",["0","0em","0px"].contains(node.attributes["width"] ?? ""),node.children.contains(where:{ containsPhantom($0) }) { return true }
        return ["mrow","mstyle"].contains(node.name) && node.children.count == 1 && isZeroPhantom(node.children[0])
    }
    private func containsPhantom(_ node:MathNode) -> Bool { node.name == "mphantom" || node.children.contains(where:containsPhantom) }
    private func largeOperator(_ node:MathNode,body:String,context c:OfficeContext) throws -> String {
        if scriptNames.contains(node.name) { try require(node,["msubsup","munderover"].contains(node.name) ? 3 : 2) }
        let b=base(node);var sub="",sup=""
        if ["msub","msubsup","munder","munderover"].contains(node.name),node.children.count > 1 { sub=try element(node.children[1],c) }
        if ["msup","mover"].contains(node.name),node.children.count > 1 { sup=try element(node.children[1],c) }
        if ["msubsup","munderover"].contains(node.name),node.children.count > 2 { sup=try element(node.children[2],c) }
        let below=c.display && (node.name.hasPrefix("munder") || node.name == "mover")
        return "<m:nary><m:naryPr><m:chr m:val=\"\(officeXML(b.string))\"/><m:limLoc m:val=\"\(below ? "undOvr" : "subSup")\"/><m:grow m:val=\"1\"/><m:subHide m:val=\"\(sub.isEmpty ? 1 : 0)\"/><m:supHide m:val=\"\(sup.isEmpty ? 1 : 0)\"/>\(control(c))</m:naryPr><m:sub>\(sub)</m:sub><m:sup>\(sup)</m:sup><m:e>\(body)</m:e></m:nary>"
    }
    private func delimiter(_ open:String,_ close:String,_ args:[[MathNode]],_ c:OfficeContext,separator:String="") throws -> String {
        let content=try args.map { wrap("e",try sequence($0,c)) }.joined()
        return "<m:d><m:dPr><m:begChr m:val=\"\(officeXML(open))\"/><m:sepChr m:val=\"\(officeXML(separator))\"/><m:endChr m:val=\"\(officeXML(close))\"/><m:grow m:val=\"1\"/>\(control(c))</m:dPr>\(content)</m:d>"
    }
    private func isAccent(_ node:MathNode,over:Bool) -> Bool {
        if let flag=node.attributes[over ? "accent" : "accentunder"] { return flag == "true" }
        let index=node.name == "munderover" && over ? 2 : 1
        guard node.children.indices.contains(index) else { return false };let marker=node.children[index]
        if let flag=marker.attributes["accent"] { return flag == "true" }
        return marker.name == "mo" && ["^","ˆ","̂","~","˜","̃","¯","‾","―","_","̲","̅","˙","̇","¨","̈","´","́","`","̀","→","⃗","ˇ","̌","˘","̆","⏞","⏟"].contains(marker.string)
    }
    private func limit(_ over:Bool,base:String,script:MathNode,accent:Bool,context c:OfficeContext) throws -> String {
        let value=script.string
        if accent && ["⏞","⏟","⏜","⏝","⎴","⎵"].contains(value) { return "<m:groupChr><m:groupChrPr><m:chr m:val=\"\(officeXML(value))\"/><m:pos m:val=\"\(over ? "top" : "bot")\"/><m:vertJc m:val=\"\(over ? "bot" : "top")\"/>\(control(c))</m:groupChrPr><m:e>\(base)</m:e></m:groupChr>" }
        if accent && ["¯","‾","―","_","̲","̅"].contains(value) { return "<m:bar><m:barPr><m:pos m:val=\"\(over ? "top" : "bot")\"/>\(control(c))</m:barPr><m:e>\(base)</m:e></m:bar>" }
        if accent && over {
            let combining:[String:String]=["^":"̂","ˆ":"̂","~":"̃","˜":"̃","˙":"̇",".":"̇","¨":"̈","´":"́","`":"̀","→":"⃗","ˇ":"̌","˘":"̆"]
            guard value.count == 1 else { throw CaptureWordFailure.unsupported("compound accent") }
            return "<m:acc><m:accPr><m:chr m:val=\"\(officeXML(combining[value] ?? value))\"/>\(control(c))</m:accPr><m:e>\(base)</m:e></m:acc>"
        }
        let tag=over ? "limUpp" : "limLow"
        return "<m:\(tag)><m:\(tag)Pr>\(control(c))</m:\(tag)Pr><m:e>\(base)</m:e><m:lim>\(try element(script,c))</m:lim></m:\(tag)>"
    }
    private func table(_ node:MathNode,_ c:OfficeContext) throws -> String {
        guard !node.children.isEmpty,node.children.count <= 1000,node.children.allSatisfy({ $0.name == "mtr" && $0.children.allSatisfy { $0.name == "mtd" } }) else { throw CaptureWordFailure.unsupported("labeled or invalid table") }
        let columns=node.children.map { $0.children.count }.max() ?? 0;guard columns > 0,columns <= 100 else { throw CaptureWordFailure.invalidMath }
        let aligns=(node.attributes["columnalign"] ?? "center").split(separator:" ").map(String.init)
        guard !aligns.isEmpty else { throw CaptureWordFailure.invalidMath }
        if node.attributes["data-break-align"] != nil || (aligns.count >= 2 && aligns[0] == "right" && aligns[1] == "left" && node.attributes["columnspacing"] == "0em") {
            let rows=try node.children.map { row -> String in
                let cells=try row.children.enumerated().map { index,cell -> String in
                    let content=try element(cell,c)
                    if index == 0 { return content }
                    if content.hasPrefix("<m:r>"),let end=content.range(of:"</m:rPr>") {
                        var aligned=content;aligned.insert(contentsOf:"<m:aln m:val=\"1\"/>",at:end.lowerBound);return aligned
                    }
                    return "<m:box><m:boxPr><m:opEmu m:val=\"1\"/><m:aln m:val=\"1\"/>\(control(c))</m:boxPr><m:e>\(content)</m:e></m:box>"
                }.joined()
                return wrap("e",cells)
            }.joined()
            return "<m:eqArr><m:eqArrPr><m:baseJc m:val=\"center\"/>\(control(c))</m:eqArrPr>\(rows)</m:eqArr>"
        }
        var definitions="",rows=""
        for i in 0..<columns {
            let align=aligns[min(i,aligns.count-1)];guard ["left","right","center"].contains(align) else { throw CaptureWordFailure.unsupported("matrix alignment") }
            definitions += "<m:mc><m:mcPr><m:count m:val=\"1\"/><m:mcJc m:val=\"\(align)\"/></m:mcPr></m:mc>"
        }
        for row in node.children { var cells="";for i in 0..<columns { cells += wrap("e",i < row.children.count ? try element(row.children[i],c) : "") };rows += wrap("mr",cells) }
        return "<m:m><m:mPr><m:baseJc m:val=\"center\"/><m:mcs>\(definitions)</m:mcs>\(control(c))</m:mPr>\(rows)</m:m>"
    }
    private func spacing(_ node:MathNode,_ c:OfficeContext) throws -> String {
        guard let width=node.attributes["width"] else { return "" }
        let normalized=width.replacingOccurrences(of:"em",with:"")
        guard width.hasSuffix("em"),let em=Double(normalized),em.isFinite,em >= 0,em <= 20 else { throw CaptureWordFailure.unsupported("space width="+width) }
        if em == 0 { return "" }
        let character=em < 0.2 ? "\u{2009}" : (em < 0.4 ? "\u{2005}" : (em < 0.8 ? "\u{2002}" : "\u{2003}"))
        return try run(String(repeating:character,count:em >= 1 ? max(1,Int(em.rounded())) : 1),c,plain:true)
    }
    private func enclosure(_ node:MathNode,_ c:OfficeContext) throws -> String {
        let notations=Set((node.attributes["notation"] ?? "longdiv").split(separator:" ").map(String.init))
        let supported:Set<String>=["box","top","bottom","left","right","updiagonalstrike","downdiagonalstrike","horizontalstrike","verticalstrike","none","radical"]
        guard notations.isSubset(of:supported) else { throw CaptureWordFailure.unsupported("enclosure "+notations.sorted().joined(separator:" ")) }
        var body=try sequence(node.children,c)
        if notations.contains("radical") { body="<m:rad><m:radPr><m:degHide m:val=\"1\"/>\(control(c))</m:radPr><m:deg/><m:e>\(body)</m:e></m:rad>" }
        if notations.subtracting(["none","radical"]).isEmpty { return body }
        var props=""
        for (side,tag) in [("top","hideTop"),("bottom","hideBot"),("left","hideLeft"),("right","hideRight")] { if !notations.contains("box") && !notations.contains(side) { props += "<m:\(tag) m:val=\"1\"/>" } }
        for (name,tag) in [("horizontalstrike","strikeH"),("verticalstrike","strikeV"),("updiagonalstrike","strikeBLTR"),("downdiagonalstrike","strikeTLBR")] { if notations.contains(name) { props += "<m:\(tag) m:val=\"1\"/>" } }
        return "<m:borderBox><m:borderBoxPr>\(props)\(control(c))</m:borderBoxPr><m:e>\(body)</m:e></m:borderBox>"
    }
    private func multiscripts(_ node:MathNode,_ c:OfficeContext) throws -> String {
        guard let first=node.children.first else { throw CaptureWordFailure.invalidMath }
        var body=try element(first,c),pre=false,i=1
        while i < node.children.count {
            if node.children[i].name == "mprescripts" { pre=true;i += 1;continue }
            guard i+1 < node.children.count else { throw CaptureWordFailure.invalidMath }
            let tag=pre ? "sPre" : "sSubSup",sub=try element(node.children[i],c),sup=try element(node.children[i+1],c)
            if pre { body="<m:sPre><m:sPrePr>\(control(c))</m:sPrePr><m:sub>\(sub)</m:sub><m:sup>\(sup)</m:sup><m:e>\(body)</m:e></m:sPre>" }
            else { body="<m:\(tag)><m:\(tag)Pr>\(control(c))</m:\(tag)Pr><m:e>\(body)</m:e><m:sub>\(sub)</m:sub><m:sup>\(sup)</m:sup></m:\(tag)>" };i += 2
        }
        return body
    }
}
