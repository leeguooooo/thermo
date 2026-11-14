import AppKit
import PreviewCore
import SwiftUI
import ThermoL10n
import WebKit

@MainActor final class MarkdownPreviewState:ObservableObject {
    let document:PreviewMarkdownDocument
    @Published var source=false
    @Published var query=""
    @Published var found:Bool?
    @Published var issue:String?
    weak var web:WKWebView?
    init(document:PreviewMarkdownDocument){self.document=document}
    func find(backwards:Bool=false) {
        let config=WKFindConfiguration();config.backwards=backwards;config.wraps=true
        let expected=query
        web?.find(query,configuration:config){[weak self] result in
            guard self?.query == expected else{return};self?.found=result.matchFound
        }
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
                Button{state.find(backwards:true)}label:{Image(systemName:"chevron.up")}
                Button{state.find()}label:{Image(systemName:"chevron.down")}.keyboardShortcut("g",modifiers:.command)
                Button(tr("Find")){finding=true}.keyboardShortcut("f",modifiers:.command).hidden().frame(width:0,height:0)
            }.buttonStyle(.plain)
            MarkdownSurface(state:state,open:{openURL($0)})
        }
    }
}

struct MarkdownSurface:NSViewRepresentable {
    @ObservedObject var state:MarkdownPreviewState
    var open:(URL)->Void = {_ in}
    func makeCoordinator()->Coordinator{Coordinator(state:state,open:open)}
    func makeNSView(context:Context)->WKWebView {
        let configuration=WKWebViewConfiguration();configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript=false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically=false
        let web=WKWebView(frame:.zero,configuration:configuration)
        web.navigationDelegate=context.coordinator;web.allowsMagnification=true
        web.underPageBackgroundColor=NSColor(calibratedRed:22/255,green:25/255,blue:31/255,alpha:1)
        state.web=web;return web
    }
    func updateNSView(_ web:WKWebView,context:Context) {
        guard context.coordinator.source != state.source else{return}
        context.coordinator.source=state.source
        let url=context.coordinator.root.appendingPathComponent("preview.html")
        do {
            try state.document.html(showSource:state.source).write(to:url,atomically:true,encoding:.utf8)
            web.loadFileURL(url,allowingReadAccessTo:context.coordinator.root)
        }catch{state.issue=error.localizedDescription}
    }
    final class Coordinator:NSObject,WKNavigationDelegate {
        let state:MarkdownPreviewState
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-markdown-preview-"+UUID().uuidString)
        var source:Bool?
        let open:(URL)->Void
        init(state:MarkdownPreviewState,open:@escaping(URL)->Void = {_ in}){self.state=state;self.open=open;super.init();try? FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)}
        deinit{try? FileManager.default.removeItem(at:root)}
        func webView(_ webView:WKWebView,decidePolicyFor action:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void) {
            guard let url=action.request.url else{decisionHandler(.cancel);return}
            let own=root.appendingPathComponent("preview.html").standardizedFileURL
            if action.navigationType == .other,url.isFileURL,url.standardizedFileURL == own{decisionHandler(.allow);return}
            if action.navigationType == .linkActivated {
                if url.isFileURL,url.standardizedFileURL == own,url.fragment != nil{decisionHandler(.allow);return}
                if ["https","http","mailto","file"].contains(url.scheme?.lowercased() ?? ""){open(url)}
            }
            decisionHandler(.cancel)
        }
        func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!){if !state.query.isEmpty{state.find()}}
    }
}
