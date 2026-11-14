import AppKit
import PreviewCore
import SwiftUI
import ThermoL10n

@MainActor final class MarkdownPreviewState:ObservableObject {
    let document:PreviewMarkdownDocument
    @Published var source=false
    @Published var query=""
    @Published var found:Bool?
    @Published var issue:String?
    weak var text:NSTextView?
    private var rendered:NSAttributedString?
    init(document:PreviewMarkdownDocument){self.document=document}
    func content() throws -> NSAttributedString {
        if source {
            return NSAttributedString(string:document.source,attributes:[.font:NSFont.monospacedSystemFont(ofSize:13,weight:.regular),.foregroundColor:NSColor.labelColor])
        }
        if let rendered{return rendered}
        // This importer produces native text/attachments in the sandbox. A WKWebView
        // requires direct network rights even for local HTML; modules do not get those.
        let value=try NSMutableAttributedString(data:Data(document.html(includeOutline:false).utf8),
            options:[.documentType:NSAttributedString.DocumentType.html,.characterEncoding:String.Encoding.utf8.rawValue],documentAttributes:nil)
        value.addAttribute(.foregroundColor,value:NSColor.labelColor,range:NSRange(location:0,length:value.length))
        rendered=value;return value
    }
    func find(backwards:Bool=false) {
        guard !query.isEmpty,let text else {found=nil;return}
        let value=text.string as NSString,selected=text.selectedRange(),length=value.length
        var options:NSString.CompareOptions=[.caseInsensitive,.diacriticInsensitive]
        if backwards{options.insert(.backwards)}
        let start=min(selected.location,length),end=min(NSMaxRange(selected),length)
        let first=backwards ? NSRange(location:0,length:start) : NSRange(location:end,length:length-end)
        var range=value.range(of:query,options:options,range:first)
        if range.location == NSNotFound {range=value.range(of:query,options:options)}
        found=range.location != NSNotFound
        if found == true{text.setSelectedRange(range);text.scrollRangeToVisible(range)}
    }
    func heading(_ title:String) {
        guard let text else{return}
        let range=(text.string as NSString).range(of:title)
        if range.location != NSNotFound{text.setSelectedRange(range);text.scrollRangeToVisible(range)}
    }
}

public struct MarkdownPreviewPane:View {
    @StateObject private var state:MarkdownPreviewState
    @FocusState private var finding:Bool
    @Environment(\.openURL) private var openURL
    public init(document:PreviewMarkdownDocument){_state=StateObject(wrappedValue:MarkdownPreviewState(document:document))}
    public var body:some View {
        VStack(spacing:8) {
            HStack(spacing:12) {
                Picker(tr("View"),selection:$state.source){Text(tr("Read")).tag(false);Text(tr("Markdown source")).tag(true)}
                    .pickerStyle(.segmented).labelsHidden().frame(width:156)
                Spacer()
                TextField(tr("Find in document"),text:$state.query).textFieldStyle(.roundedBorder).frame(width:180)
                    .focused($finding).onSubmit{state.find()}.onChange(of:state.query){_ in state.find()}
                if state.found == false {Text(tr("No matches")).font(.caption).foregroundStyle(.secondary)}
                if !state.query.isEmpty {
                    Button{state.find(backwards:true)}label:{Image(systemName:"chevron.up")}.help(tr("Previous match")).accessibilityLabel(tr("Previous match"))
                    Button{state.find()}label:{Image(systemName:"chevron.down")}.help(tr("Next match")).accessibilityLabel(tr("Next match")).keyboardShortcut("g",modifiers:.command)
                    Button{state.query=""}label:{Image(systemName:"xmark.circle.fill")}.accessibilityLabel(tr("Clear search"))
                }
                Button(tr("Find")){finding=true}.keyboardShortcut("f",modifiers:.command).hidden().frame(width:0,height:0)
            }.buttonStyle(.plain)
            if let issue=state.issue {Text(issue).foregroundStyle(.secondary).textSelection(.enabled)}
            HStack(alignment:.top,spacing:12) {
                if !state.source,state.document.headings.count >= 3 {
                    ScrollView {VStack(alignment:.leading,spacing:8) {
                        ForEach(Array(state.document.headings.enumerated()),id:\.offset) {_,heading in
                            Button(heading.title){state.heading(heading.title)}.buttonStyle(.plain)
                                .padding(.leading,CGFloat(max(0,heading.level-1)*8)).multilineTextAlignment(.leading)
                        }
                    }.padding(8)}.frame(width:164)
                }
                MarkdownSurface(state:state,open:{openURL($0)})
            }
        }
    }
}

@MainActor struct MarkdownSurface:NSViewRepresentable {
    @ObservedObject var state:MarkdownPreviewState
    var open:(URL)->Void = {_ in}
    func makeCoordinator()->Coordinator{Coordinator(state:state,open:open)}
    func makeNSView(context:Context)->NSScrollView {
        let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.drawsBackground=false
        let text=NSTextView(frame:.zero)
        text.isEditable=false;text.isSelectable=true;text.isRichText=true;text.importsGraphics=true
        text.isVerticallyResizable=true;text.isHorizontallyResizable=false;text.autoresizingMask=[.width]
        text.maxSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView=true;text.textContainerInset=NSSize(width:24,height:24)
        text.backgroundColor=NSColor(calibratedRed:22/255,green:25/255,blue:31/255,alpha:1)
        text.linkTextAttributes=[.foregroundColor:NSColor.systemBlue,.underlineStyle:NSUnderlineStyle.single.rawValue]
        text.delegate=context.coordinator;scroll.documentView=text
        scroll.appearance=NSAppearance(named:.darkAqua);state.text=text;return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        guard context.coordinator.source != state.source,let text=scroll.documentView as? NSTextView else{return}
        context.coordinator.source=state.source;context.coordinator.load(text)
    }
    @MainActor final class Coordinator:NSObject,NSTextViewDelegate {
        let state:MarkdownPreviewState
        var source:Bool?
        let open:(URL)->Void
        init(state:MarkdownPreviewState,open:@escaping(URL)->Void = {_ in}){self.state=state;self.open=open;super.init()}
        func load(_ text:NSTextView) {
            do {text.textStorage?.setAttributedString(try state.content());state.issue=nil;state.text=text;state.find()}
            catch{state.issue=error.localizedDescription}
        }
        func textView(_ textView:NSTextView,clickedOnLink link:Any,at charIndex:Int)->Bool {
            let url=(link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url else{return true}
            if let fragment=url.fragment,let heading=state.document.headings.first(where:{$0.anchor==fragment}){state.heading(heading.title);return true}
            if ["https","http","mailto","file"].contains(url.scheme?.lowercased() ?? ""){open(url)}
            return true
        }
    }
}
