import AppKit
import QuickLookUI
import SearchCore
import SwiftUI
import ThermoL10n
import WebKit

@MainActor final class SearchFilePreviewModel: ObservableObject {
    let item: SearchItem
    @Published var document: SearchMarkdownDocument?
    @Published var issue: String?
    @Published var loading = false
    @Published var showSource = false
    @Published var findQuery = ""
    @Published var findResult: Bool?
    weak var webView: WKWebView?

    init(item: SearchItem) { self.item = item }
    var isMarkdown: Bool { SearchMarkdownDocument.supports(URL(fileURLWithPath: item.path)) && item.kind == .file }
    func load() async {
        guard isMarkdown, document == nil, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let url = URL(fileURLWithPath: item.path)
            let result = try await Task.detached(priority: .userInitiated) { try SearchMarkdownDocument.load(url) }.value
            guard !Task.isCancelled else { return }
            document = result
        } catch { if !Task.isCancelled { issue = error.localizedDescription } }
    }
    func find(backwards: Bool = false) {
        guard !findQuery.isEmpty else {
            findResult = nil
            webView?.find("", configuration: WKFindConfiguration()) { _ in }
            return
        }
        let configuration = WKFindConfiguration(); configuration.backwards = backwards; configuration.wraps = true
        let query = findQuery
        webView?.find(query, configuration: configuration) { [weak self] result in
            guard self?.findQuery == query else { return }
            self?.findResult = result.matchFound
        }
    }
}

struct SearchFilePreviewView: View {
    @StateObject private var model: SearchFilePreviewModel
    let open: () -> Void
    let reveal: () -> Void
    @FocusState private var finding: Bool
    init(item: SearchItem, open: @escaping () -> Void, reveal: @escaping () -> Void) {
        _model = StateObject(wrappedValue: SearchFilePreviewModel(item: item)); self.open = open; self.reveal = reveal
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: model.item.path)).resizable().frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.item.name).font(Theme.rowTitle).lineLimit(1).truncationMode(.middle)
                    Text((model.item.path as NSString).deletingLastPathComponent).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 12)
                Button(action: reveal) { Image(systemName: "folder") }.help(tr("Show in Finder")).accessibilityLabel(tr("Show in Finder"))
                Button(tr("Open"), action: open)
            }.padding(.horizontal, 20).padding(.vertical, 12)
            if model.document != nil {
                HStack(spacing: 16) {
                    Picker(tr("View"), selection: $model.showSource) {
                        Text(tr("Read")).tag(false)
                        Text(tr("Markdown source")).tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 156)
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary)
                        TextField(tr("Find in document"), text: $model.findQuery).textFieldStyle(.plain).focused($finding)
                            .onSubmit { model.find() }.onChange(of: model.findQuery) { _ in model.find() }
                        if model.findResult == false { Text(tr("No matches")).font(Theme.caption).foregroundStyle(Theme.textSecondary) }
                        if !model.findQuery.isEmpty {
                            Button { model.find(backwards: true) } label: { Image(systemName: "chevron.up") }.help(tr("Previous match")).accessibilityLabel(tr("Previous match"))
                            Button { model.find() } label: { Image(systemName: "chevron.down") }.help(tr("Next match")).accessibilityLabel(tr("Next match"))
                            Button { model.findQuery = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel(tr("Clear search"))
                        }
                    }.frame(width: 280).padding(.horizontal, 10).padding(.vertical, 6).background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 6))
                    Button(tr("Find")) { finding = true }.keyboardShortcut("f", modifiers: .command).hidden().frame(width: 0, height: 0)
                }.buttonStyle(.plain).padding(.horizontal, 20).padding(.bottom, 10)
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if model.isMarkdown {
                if let issue = model.issue {
                    VStack(spacing: 16) {
                        Image(systemName: "doc.text.magnifyingglass").font(.system(size: 36, weight: .light)).foregroundStyle(Theme.textSecondary)
                        Text(tr("Unable to preview this document")).font(Theme.heading)
                        Text(tr(issue)).font(Theme.body).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                        Button(tr("Open"), action: open)
                    }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let document = model.document {
                    SearchMarkdownWebView(document: document, model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            } else { SearchQuickLookView(url: URL(fileURLWithPath: model.item.path)) }
        }.foregroundStyle(Theme.textPrimary).background(Theme.canvas).preferredColorScheme(.dark)
            .task { await model.load() }
    }
}

private struct SearchQuickLookView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> NSView {
        if let view = QLPreviewView(frame: .zero, style: .normal) {
            // dismantleNSView closes it. With `true`, QuickLook also closes it with the window and
            // the second close aborts the app (-[QLPreviewView deactivate] assertion).
            view.shouldCloseWithWindow = false; return view
        }
        let message = NSTextField(labelWithString: tr("Unable to preview this document"))
        message.alignment = .center
        return message
    }
    func updateNSView(_ view: NSView, context: Context) { (view as? QLPreviewView)?.previewItem = url as NSURL }
    static func dismantleNSView(_ view: NSView, coordinator: ()) { (view as? QLPreviewView)?.close() }
}

struct SearchMarkdownWebView: NSViewRepresentable {
    let document: SearchMarkdownDocument
    @ObservedObject var model: SearchFilePreviewModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator; web.allowsMagnification = true
        web.underPageBackgroundColor = NSColor(calibratedRed: 22.0 / 255, green: 25.0 / 255, blue: 31.0 / 255, alpha: 1)
        model.webView = web
        return web
    }
    func updateNSView(_ web: WKWebView, context: Context) {
        guard context.coordinator.showSource != model.showSource else { return }
        context.coordinator.showSource = model.showSource
        // Images are embedded by the background renderer. WebKit only reads this owned temporary page.
        do {
            let html = document.html(showSource: model.showSource)
            let url = context.coordinator.directory.appendingPathComponent("preview.html")
            try html.write(to: url, atomically: true, encoding: .utf8)
            web.loadFileURL(url, allowingReadAccessTo: context.coordinator.directory)
        } catch { model.issue = error.localizedDescription }
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        let model: SearchFilePreviewModel
        let directory: URL
        var showSource: Bool?
        init(model: SearchFilePreviewModel) {
            self.model = model
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-markdown-" + UUID().uuidString)
            super.init()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if action.navigationType == .other, url.isFileURL, SearchPaths.canonical(url.path) == SearchPaths.canonical(directory.appendingPathComponent("preview.html").path) { decisionHandler(.allow); return }
            if action.navigationType == .linkActivated {
                if url.isFileURL, SearchPaths.canonical(url.path) == SearchPaths.canonical(directory.appendingPathComponent("preview.html").path), url.fragment != nil { decisionHandler(.allow); return }
                if ["https", "http", "mailto", "file"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
            }
            decisionHandler(.cancel)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { model.issue = error.localizedDescription }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { model.issue = error.localizedDescription }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if !model.findQuery.isEmpty { model.find() }
        }
    }
}
