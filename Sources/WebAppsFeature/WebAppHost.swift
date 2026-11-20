import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// One web app's web view. Pages come only from the app's own folder through `thermo-webapp://`;
/// every http(s) load is blocked, so analytics and the Puter SDK never leave the Mac.
@MainActor final class WebAppHost: NSObject {
    static let scheme = "thermo-webapp"
    let app: WebApp
    let webView: WKWebView
    private let files: WebAppSchemeHandler
    private var store: WebAppLocalStore?
    private var downloads: [WKDownload: URL] = [:]

    init(app: WebApp, root: URL) {
        self.app = app
        files = WebAppSchemeHandler(root: root)
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(files, forURLScheme: Self.scheme)
        // Separate storage per app: one app cannot read another's local data.
        config.websiteDataStore = .dedicated(for: app)
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let controller = config.userContentController
        if app.needsLocalStore {
            let store = WebAppLocalStore(directory: WebAppResources.dataDirectory(for: app))
            controller.addScriptMessageHandler(store, contentWorld: .page, name: WebAppLocalStore.handlerName)
            controller.addUserScript(.init(source: WebAppLocalStore.shim, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            self.store = store
        }
        webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        super.init()
        webView.uiDelegate = self
        webView.navigationDelegate = self
        Self.installNetworkBlock(on: controller) { [weak self] in
            guard let self else { return }
            self.webView.load(URLRequest(url: URL(string: "\(Self.scheme)://\(app.slug)/index.html")!))
        }
    }

    func close() {
        webView.stopLoading()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.removeFromSuperview()
        store = nil
    }

    /// Blocks every network URL before the first page loads. If the rule list cannot compile the page
    /// is not loaded at all rather than loaded unblocked.
    private static func installNetworkBlock(on controller: WKUserContentController, then load: @escaping @MainActor () -> Void) {
        // WebKit's rule regexes have no alternation, hence one rule per scheme family.
        let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "dev.thermo.webapps.offline.v2", encodedContentRuleList: rules) { list, _ in
            Task { @MainActor in
                guard let list else { return }
                controller.add(list)
                load()
            }
        }
    }
}

private extension WKWebsiteDataStore {
    /// A persistent store of its own per app (macOS 14+); older systems share the default store.
    @MainActor static func dedicated(for app: WebApp) -> WKWebsiteDataStore {
        if #available(macOS 14.0, *) {
            return WKWebsiteDataStore(forIdentifier: app.storeIdentifier)
        }
        return .default()
    }
}

extension WebApp {
    /// Stable per app; changing it would lose the app's saved browser data.
    var storeIdentifier: UUID {
        switch self {
        case .pdf: return UUID(uuidString: "6B2F7C1E-4A0D-4E57-9A1B-0C5D2E8F3A01")!
        case .photoStudio: return UUID(uuidString: "6B2F7C1E-4A0D-4E57-9A1B-0C5D2E8F3A02")!
        case .timeTracking: return UUID(uuidString: "6B2F7C1E-4A0D-4E57-9A1B-0C5D2E8F3A03")!
        }
    }
}

extension WebAppHost: WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        switch url.scheme {
        case Self.scheme, "blob", "data", "about":
            decisionHandler(action.shouldPerformDownload ? .download : .allow)
        case "http", "https", "mailto":
            // A link the person clicked opens in their browser; nothing loads inside the app.
            if action.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        default:
            decisionHandler(.cancel)
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return completionHandler(nil) }
        try? FileManager.default.removeItem(at: url)  // The panel already confirmed replacing it.
        downloads[download] = url
        completionHandler(url)
    }
    func downloadDidFinish(_ download: WKDownload) { downloads[download] = nil }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) { downloads[download] = nil }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        completionHandler(panel.runModal() == .OK ? panel.urls : nil)
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        let alert = NSAlert(); alert.messageText = message; alert.runModal(); completionHandler()
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert(); alert.messageText = message
        alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }
    /// `window.open` (e.g. a print preview) stays inside the same view instead of a new window.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, url.scheme == "http" || url.scheme == "https" { NSWorkspace.shared.open(url) }
        else if action.request.url != nil { webView.load(action.request) }
        return nil
    }
}

/// Serves the app's built files. Paths cannot leave the app's folder.
final class WebAppSchemeHandler: NSObject, WKURLSchemeHandler {
    let root: URL
    init(root: URL) { self.root = root.standardizedFileURL }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let file = Self.file(for: url, in: root),
              let data = try? Data(contentsOf: file) else {
            let response = HTTPURLResponse(url: task.request.url ?? root, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!
            task.didReceive(response); task.didReceive(Data()); task.didFinish()
            return
        }
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? Self.fallbackType(file.pathExtension)
        let headers = ["Content-Type": type, "Content-Length": String(data.count),
                       // Lets pdf.js and OCR use shared memory and workers as on the web.
                       "Cross-Origin-Opener-Policy": "same-origin", "Cross-Origin-Embedder-Policy": "require-corp",
                       "Cross-Origin-Resource-Policy": "same-origin", "Cache-Control": "no-cache"]
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    static func file(for url: URL, in root: URL) -> URL? {
        var path = url.path.removingPercentEncoding ?? url.path
        if path.isEmpty || path.hasSuffix("/") { path += "index.html" }
        let file = root.appendingPathComponent(path).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/") else { return nil }
        return file
    }
    static func fallbackType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "js", "mjs": return "text/javascript"
        case "wasm": return "application/wasm"
        case "traineddata", "bcmap", "pfb": return "application/octet-stream"
        default: return "application/octet-stream"
        }
    }
}

/// Full-bleed page; the title bar area above stays draggable.
struct WebAppPage: NSViewRepresentable {
    let host: WebAppHost
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }
    func updateNSView(_ container: NSView, context: Context) {
        if host.webView.superview !== container { attach(to: container) }
    }
    private func attach(to container: NSView) {
        let web = host.webView
        web.removeFromSuperview()
        web.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            web.topAnchor.constraint(equalTo: container.topAnchor, constant: 28),
        ])
    }
}
