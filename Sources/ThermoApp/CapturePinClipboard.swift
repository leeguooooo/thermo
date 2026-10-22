import AppKit
import CaptureCore

@MainActor enum CapturePinClipboard {
    enum Value { case image(CGImage),content(CapturePinContent) }
    static func read(_ board:NSPasteboard,asText:Bool=false,asLaTeX:Bool=false) throws -> Value {
        if !asText,!asLaTeX,let urls=board.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL],!urls.isEmpty {
            guard urls.count <= 100 else { throw CapturePinFailure.invalidContent }
            return .content(.files(try urls.map { try CapturePinFile(url:$0) }))
        }
        if !asText,!asLaTeX,let image=NSImage(pasteboard:board),let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil) { return .image(cg) }
        let html=board.string(forType:.html),rtf=board.data(forType:.rtf)
        var plain=board.string(forType:.string) ?? ""
        if plain.isEmpty,let rtf {
            guard rtf.count <= 4*1024*1024 else { throw CapturePinFailure.invalidContent }
            plain=try CapturePinText(plain:"",rtf:rtf).attributed().string
        }
        if asLaTeX { let formula=CaptureLaTeX(source:plain);guard formula.valid else { throw CapturePinFailure.invalidContent };return .content(.latex(formula)) }
        if !asText,let formula=CaptureLaTeX.detect(plain) { return .content(.latex(formula)) }
        if !asText,let color=CapturePinColor.parse(plain) { return .content(.color(color)) }
        guard !plain.isEmpty || html != nil || rtf != nil else { throw CaptureFailure.unsupportedClipboard }
        let content=CapturePinContent.text(.init(plain:plain,html:html,rtf:rtf));guard content.valid else { throw CapturePinFailure.invalidContent };return .content(content)
    }
    enum MathFormat { case svg,mathml }
    static func copyFormula(_ formula:CaptureLaTeX,format:MathFormat,to board:NSPasteboard) throws {
        let result=try formula.render(),value=format == .svg ? result.svg : result.mathml
        board.clearContents();board.setString(value,forType:.string);board.setData(Data(value.utf8),forType:.init(format == .svg ? "public.svg-image" : "public.mathml"))
    }
    static func copy(_ content:CapturePinContent,to board:NSPasteboard,format:CapturePinColor.Format = .hex,selectedFiles:Set<UUID>? = nil) throws {
        guard content.valid else { throw CapturePinFailure.invalidContent }
        switch content {
        case .latex(let formula):board.clearContents();board.setString(formula.source,forType:.string)
        case .text(let text):
            board.clearContents();board.setString(text.plain,forType:.string)
            if let html=text.html { board.setString(html,forType:.html) }
            if let rtf=text.rtf { board.setData(rtf,forType:.rtf) }
        case .color(let color):board.clearContents();board.setString(color.formatted(format),forType:.string)
        case .files(let files):
            let selected=files.filter { selectedFiles == nil || selectedFiles!.contains($0.id) },urls=try selected.map { try $0.resolved() }
            guard !urls.isEmpty else { return }
            board.clearContents();guard board.writeObjects(urls as [NSURL]) else { throw CaptureFailure.exportFailed }
        }
    }
}
