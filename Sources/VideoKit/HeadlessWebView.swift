import AppKit
import Foundation
import WebKit
import os

/// Hidden-browser extraction, for pages that only yield data after running JavaScript.
public protocol HeadlessFetching: Sendable {
    /// Loads `url`, polls `readyCheckJS` until true, then returns `extractJS`'s value as text.
    /// Returns nil on timeout, load failure or when the browser is unavailable, so callers fall
    /// back to plain HTTP. `userAgent` is kept for parity; see `HeadlessWebView`.
    func loadAndExtract(
        url: String,
        userAgent: String,
        readyCheckJS: String,
        extractJS: String,
        timeout: TimeInterval,
        pollInterval: TimeInterval,
        documentStartJS: [String]
    ) async -> String?

    /// Warms the renderer and site cookies in the background. Failure has no effect.
    func prewarm(url: String) async
}

extension HeadlessFetching {
    public func loadAndExtract(
        url: String,
        userAgent: String,
        readyCheckJS: String,
        extractJS: String,
        documentStartJS: [String] = []
    ) async -> String? {
        await loadAndExtract(
            url: url,
            userAgent: userAgent,
            readyCheckJS: readyCheckJS,
            extractJS: extractJS,
            timeout: 25,
            pollInterval: 0.12,
            documentStartJS: documentStartJS
        )
    }
}

/// The process-wide hidden page, reachable from any isolation. Created on first use, so building
/// `VideoParsers` never starts a web process.
public struct SharedHeadlessWebView: HeadlessFetching {
    @MainActor private static let shared = HeadlessWebView()

    public init() {}

    public func loadAndExtract(
        url: String,
        userAgent: String,
        readyCheckJS: String,
        extractJS: String,
        timeout: TimeInterval,
        pollInterval: TimeInterval,
        documentStartJS: [String]
    ) async -> String? {
        await Self.shared.loadAndExtract(
            url: url, userAgent: userAgent, readyCheckJS: readyCheckJS, extractJS: extractJS,
            timeout: timeout, pollInterval: pollInterval, documentStartJS: documentStartJS
        )
    }

    public func prewarm(url: String) async {
        await Self.shared.prewarm(url: url)
    }
}

/// The browser operations `HeadlessWebView` needs. `WKHeadlessPage` is the real one.
@MainActor
public protocol HeadlessPage: AnyObject {
    var currentURL: String? { get }
    /// A main-frame load failed. Aborted navigations from redirects must not be reported.
    var onLoadFailed: (() -> Void)? { get set }
    var onLoadFinished: (() -> Void)? { get set }
    /// Replaces the scripts run at document start of each main-frame document.
    func setDocumentStartScripts(_ scripts: [String])
    func load(_ url: String)
    func reload()
    /// The script's value, or nil if it failed.
    func evaluate(_ script: String) async -> Any?
}

/// One long-lived hidden page reused across requests, because almost all of a parse's time goes
/// to the first navigation. Requests run one at a time.
///
/// Each session writes a token at document start and the ready probe requires it, so a reused
/// page can never answer from the previous document. The page parks on about:blank after
/// `parkDelay` idle: site feeds autoplay, and a hidden page still decodes.
///
/// `userAgent` is deliberately not applied, matching YunX: rewriting it on a real browser makes
/// the headers disagree with the rest of the fingerprint.
@MainActor
public final class HeadlessWebView: HeadlessFetching {
    private static let logger = Logger(subsystem: "com.thermo.VideoKit", category: "headless")
    private static let blank = "about:blank"

    private final class Session {
        let token: String
        var failed = false

        init(token: String) {
            self.token = token
        }
    }

    private let makePage: @MainActor () -> (any HeadlessPage)?
    private let parkDelay: TimeInterval
    private var page: (any HeadlessPage)?
    private var active: Session?
    private var tokenSeq = 0
    private var parkTask: Task<Void, Never>?

    public init(
        parkDelay: TimeInterval = 3,
        makePage: @escaping @MainActor () -> (any HeadlessPage)? = { WKHeadlessPage() }
    ) {
        self.parkDelay = parkDelay
        self.makePage = makePage
    }

    public func loadAndExtract(
        url: String,
        userAgent: String,
        readyCheckJS: String,
        extractJS: String,
        timeout: TimeInterval,
        pollInterval: TimeInterval,
        documentStartJS: [String]
    ) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        // The wait counts against the timeout, as it did under YunX's mutex.
        while active != nil {
            guard await pause(pollInterval, until: deadline) else {
                Self.logTimeout(url)
                return nil
            }
        }

        tokenSeq += 1
        let session = Session(token: "t\(tokenSeq)")
        let reused = page != nil
        guard let page = ensurePage() else { return nil }
        active = session
        defer {
            active = nil
            parkWhenIdle()
        }

        page.setDocumentStartScripts([Self.markerJS(session.token)] + documentStartJS)
        // Same URL reloads, for a fresh JS context.
        if reused, page.currentURL == url { page.reload() } else { page.load(url) }

        let probe = Self.probeJS(readyCheckJS, token: session.token)
        let extract = Self.extractJS(extractJS)
        while !session.failed {
            if await Self.evaluate(probe, on: page, until: deadline) as? Bool == true {
                let result = await Self.evaluate(extract, on: page, until: deadline) as? String
                if session.failed { return nil }
                return result
            }
            guard await pause(pollInterval, until: deadline) else {
                Self.logTimeout(url)
                return nil
            }
        }
        return nil
    }

    public func prewarm(url: String) async {
        guard page == nil, active == nil, let page = ensurePage() else { return }
        page.load(url)
    }

    private func ensurePage() -> (any HeadlessPage)? {
        if let page { return page }
        guard let created = makePage() else { return nil }
        created.onLoadFailed = { [weak self] in self?.active?.failed = true }
        // A prewarm navigation has no session to end it, so it parks here.
        created.onLoadFinished = { [weak self] in
            if self?.active == nil { self?.parkWhenIdle() }
        }
        page = created
        return created
    }

    /// Sleeps one interval. False when the deadline passed or the task was cancelled.
    private func pause(_ interval: TimeInterval, until deadline: Date) async -> Bool {
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 || Task.isCancelled { return false }
        let nanoseconds = UInt64(min(interval, remaining) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
        return !Task.isCancelled && deadline.timeIntervalSinceNow > 0
    }

    /// A wedged web process never answers, so a call is bounded by the deadline and the task too.
    private static func evaluate(_ script: String, on page: any HeadlessPage, until deadline: Date) async -> Any? {
        let waiter = EvaluationWaiter()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<UncheckedAny, Never>) in
                waiter.continuation = continuation
                let timer = Task { @MainActor in
                    let remaining = max(deadline.timeIntervalSinceNow, 0)
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    if !Task.isCancelled { waiter.finish(nil) }
                }
                Task { @MainActor in
                    let value = await page.evaluate(script)
                    timer.cancel()
                    waiter.finish(value)
                }
            }
        } onCancel: {
            Task { @MainActor in waiter.finish(nil) }
        }.value
    }

    private func parkWhenIdle() {
        parkTask?.cancel()
        let delay = UInt64(parkDelay * 1_000_000_000)
        parkTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self, self.active == nil, let page = self.page,
                  let current = page.currentURL, current != Self.blank else { return }
            page.load(Self.blank)
        }
    }

    private static func logTimeout(_ url: String) {
        logger.warning("headless timeout: \(VideoHttp.redactedURL(url), privacy: .public)")
    }

    static func markerJS(_ token: String) -> String {
        "window.__thermoSessionToken='\(token)';"
    }

    /// Compares against true and 'true' because ready checks return strings and 'false' is truthy.
    static func probeJS(_ readyCheckJS: String, token: String) -> String {
        "(function(){try{if(window.__thermoSessionToken!=='\(token)')return false;" +
            "var r=(\n\(readyCheckJS)\n);return r===true||r==='true';}catch(e){return false;}})()"
    }

    static func extractJS(_ extractJS: String) -> String {
        "(function(){try{var r=(\n\(extractJS)\n);" +
            "return (typeof r==='string')?r:JSON.stringify(r);}catch(e){return '{\"error\":\"js-wrap\"}';}})()"
    }
}

/// Whichever of answer, deadline or cancellation comes first resumes the caller.
@MainActor
private final class EvaluationWaiter {
    var continuation: CheckedContinuation<UncheckedAny, Never>?

    func finish(_ value: Any?) {
        continuation?.resume(returning: UncheckedAny(value: value))
        continuation = nil
    }
}

/// Offscreen WKWebView, hosted in an invisible window so WebKit has one to treat as visible. Timers
/// run either way; animation frames did not fire under `swift test`, where the page stays `hidden`,
/// so a site that waits on them needs checking in the running app. Uses a non-persistent data store: site cookies stay warm for the process
/// lifetime and nothing is written to disk.
@MainActor
public final class WKHeadlessPage: NSObject, HeadlessPage, WKNavigationDelegate {
    private let webView: WKWebView
    private let window: NSWindow
    public var onLoadFailed: (() -> Void)?
    public var onLoadFinished: (() -> Void)?

    public override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        // WebKit's default names no browser at all. This keeps the UA consistent with the engine.
        configuration.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
        window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        super.init()
        webView.navigationDelegate = self
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.contentView = webView
        window.orderFrontRegardless()
    }

    public var currentURL: String? { webView.url?.absoluteString }

    public func setDocumentStartScripts(_ scripts: [String]) {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        for script in scripts {
            controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
    }

    public func load(_ url: String) {
        guard let target = URL(string: url) else {
            onLoadFailed?()
            return
        }
        webView.load(URLRequest(url: target))
    }

    public func reload() {
        webView.reload()
    }

    public func evaluate(_ script: String) async -> Any? {
        await withCheckedContinuation { (continuation: CheckedContinuation<UncheckedAny, Never>) in
            webView.evaluateJavaScript(script) { value, _ in
                continuation.resume(returning: UncheckedAny(value: value))
            }
        }.value
    }

    /// App deep links would fail the main frame and end the session.
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        decisionHandler(["http", "https", "about", "data"].contains(scheme) ? .allow : .cancel)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onLoadFinished?()
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        reportFailure(error)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        reportFailure(error)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        onLoadFailed?()
    }

    private func reportFailure(_ error: Error) {
        let error = error as NSError
        // Redirects and challenge reloads abort the previous navigation; that is not a failure.
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
        onLoadFailed?()
    }
}

private struct UncheckedAny: @unchecked Sendable {
    let value: Any?
}
