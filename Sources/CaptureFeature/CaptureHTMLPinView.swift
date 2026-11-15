import AppKit
import CaptureCore
import SwiftUI
import WebKit

struct CaptureHTMLPinView:NSViewRepresentable {
    let text:CapturePinText
    let model:CaptureEditorModel
    func makeCoordinator() -> Coordinator { Coordinator(model:model) }
    func makeNSView(context:Context) -> WKWebView {
        let config=WKWebViewConfiguration();config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript=false;config.preferences.javaScriptCanOpenWindowsAutomatically=false
        let view=WKWebView(frame:.zero,configuration:config);view.navigationDelegate=context.coordinator
        let coordinator=context.coordinator
        model.snapshotPinContent={ [weak view,weak coordinator] in
            guard coordinator?.ready == true,let view,view.bounds.width > 0,view.bounds.height > 0,!view.isLoading else { throw CaptureFailure.invalidImage }
            let image=try await view.takeSnapshot(configuration:nil)
            guard let result=image.cgImage(forProposedRect:nil,context:nil,hints:nil) else { throw CaptureFailure.invalidImage };return result
        }
        return view
    }
    func updateNSView(_ view:WKWebView,context:Context) {
        view.allowsMagnification = !model.locked
        if abs(view.magnification-model.zoom) > 0.001 { view.magnification=model.zoom }
        let html=text.isolatedHTML
        guard context.coordinator.html != html else { return };context.coordinator.html=html;context.coordinator.ready=false
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier:"ThermoOfflinePinHTML-v1",encodedContentRuleList:Self.rules) { [weak view] rules,error in
            guard let view,context.coordinator.html == html else { return }
            if let error { model.error=error.localizedDescription;return }
            guard let rules else { model.error=CaptureFailure.invalidImage.localizedDescription;return }
            view.configuration.userContentController.removeAllContentRuleLists();view.configuration.userContentController.add(rules)
            view.loadHTMLString(html,baseURL:nil)
        }
    }
    static let rules="""
    [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^file:"},"action":{"type":"block"}},{"trigger":{"url-filter":"^ftp:"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?:"},"action":{"type":"block"}}]
    """
    final class Coordinator:NSObject,WKNavigationDelegate {
        let model:CaptureEditorModel
        var html:String?
        var ready=false
        init(model:CaptureEditorModel) { self.model=model }
        func webView(_ webView:WKWebView,decidePolicyFor action:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void) {
            decisionHandler(action.navigationType == .other && action.targetFrame?.isMainFrame == true && action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
        }
        func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) {
            ready=true
            // This constant host script extracts text; page-authored scripts remain disabled.
            guard case .text(let value)=model.pinContent,value.plain.isEmpty else { return }
            webView.evaluateJavaScript("document.body.innerText") { [weak self] result,error in
                guard let self,let plain=result as? String,plain.utf8.count <= 1024*1024,case .text(var current)=self.model.pinContent,current.plain.isEmpty,current.html == value.html,current.usesHTML else { return }
                current.plain=plain
                do { try self.model.updatePinContent(.text(current),derivedHTMLText:true) } catch { self.model.error=error.localizedDescription }
            }
        }
        func webView(_ webView:WKWebView,didFail navigation:WKNavigation!,withError error:Error) { model.error=error.localizedDescription }
        func webView(_ webView:WKWebView,didFailProvisionalNavigation navigation:WKNavigation!,withError error:Error) { model.error=error.localizedDescription }
    }
}
