import Foundation

/// Which Chrome page is the problem: per page JavaScript memory, DOM nodes and event listeners,
/// sampled twice through the DevTools protocol and compared — so a page that leaks (listeners piling
/// up, memory climbing) stands out from one that is merely big. Also duplicate tabs, workers per
/// site, and pages that are in no window (automation).
///
/// Read-only and on request only: it reads metrics, titles and URLs, never page content; it attaches
/// to one page at a time and detaches right after. Pages with no URL (other automation sessions'
/// tabs, masked by the relay) are counted, never touched.
public enum ChromeInspector {
    // MARK: - Samples

    /// One page or worker at one moment. Coding keys match Chrome's metric names, so a raw probe
    /// dump (`{at, rows}`) decodes as is.
    public struct Target: Codable, Sendable, Equatable {
        public var targetId: String
        /// page | worker | service_worker
        public var type: String
        public var url: String
        public var title: String
        public var attached: Bool?
        /// Bytes of JavaScript heap in use.
        public var heap: Double?
        public var nodes: Double?
        public var listeners: Double?
        public var documents: Double?
        public var error: String?
        /// A page with no address, checked: true when it did not answer (a dead record in a
        /// DevTools relay, not a page), false when it is a real page in no window.
        public var ghost: Bool?

        enum CodingKeys: String, CodingKey {
            case targetId, type, url, title, attached, error, ghost
            case heap = "JSHeapUsedSize", nodes = "Nodes", listeners = "JSEventListeners", documents = "Documents"
        }

        public init(targetId: String, type: String, url: String, title: String, attached: Bool? = nil,
                    heap: Double? = nil, nodes: Double? = nil, listeners: Double? = nil, documents: Double? = nil, error: String? = nil,
                    ghost: Bool? = nil) {
            self.targetId = targetId; self.type = type; self.url = url; self.title = title; self.attached = attached
            self.heap = heap; self.nodes = nodes; self.listeners = listeners; self.documents = documents; self.error = error
            self.ghost = ghost
        }
    }

    public struct Snapshot: Codable, Sendable, Equatable {
        /// Milliseconds since 1970 (as the probe writes it).
        public var at: Double
        public var rows: [Target]
        public var date: Date { Date(timeIntervalSince1970: at / 1000) }
        public init(at: Date, rows: [Target]) { self.at = at.timeIntervalSince1970 * 1000; self.rows = rows }
    }

    // MARK: - Report

    public enum Leak: String, Codable, Sendable { case listeners, heap, nodes }

    public struct Growth: Codable, Sendable, Equatable {
        public var seconds: Double
        /// MiB; the legacy field name is kept for JSON compatibility.
        public var heapMB: Double
        public var nodes: Int
        public var listeners: Int
    }

    public struct Page: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var url: String
        public var title: String
        public var heapMB: Double
        public var nodes: Int
        public var listeners: Int
        /// Between the two samples, when there were two.
        public var growth: Growth?
        public var leak: Leak?
        /// Plain words: what is wrong and what to do.
        public var advice: String?
    }

    public struct Duplicate: Codable, Sendable, Equatable, Identifiable {
        public var url: String
        public var title: String
        public var count: Int
        public var id: String { url }
    }

    public struct SiteWorkers: Codable, Sendable, Equatable, Identifiable {
        public var site: String
        public var count: Int
        public var heapMB: Double
        public var id: String { site }
    }

    public struct Report: Codable, Sendable, Equatable {
        public var sampled: Date
        /// Seconds between the two samples; nil after a single one (no leak check).
        public var seconds: Double?
        /// Pages in windows that could be measured, biggest first.
        public var pages: [Page]
        /// Growing pages, worst first.
        public var leaking: [Page]
        /// The biggest pages that are not growing.
        public var largest: [Page]
        public var duplicates: [Duplicate]
        /// Sites running many workers, most first.
        public var workers: [SiteWorkers]
        /// Real pages with no address in no window (automation tools' tabs).
        public var hidden: Int
        /// Their JavaScript memory.
        public var hiddenHeapMB: Double
        /// Targets with no address that are not pages at all: dead records a DevTools relay
        /// (chrome-use) still lists. Never counted as memory.
        public var stale: Int
        /// Pages that refused to be measured (chrome:// pages, protected extensions).
        public var unmeasured: Int
        public var pagesHeapMB: Double
        public var workersHeapMB: Double
        public var workerCount: Int
    }

    /// Per-minute rates above which a page counts as growing.
    public struct Limits: Sendable {
        /// JavaScript heap growth, MB per minute (and at least `heapMinMB` in all).
        public var heapMBPerMinute: Double = 1.5
        public var heapMinMB: Double = 2
        /// Listeners added while the page barely changed: more than this many, with nodes growing by
        /// less than a tenth of that.
        public var listeners: Int = 100
        public var nodesPerMinute: Double = 1000
        /// Sites with at least this many workers are listed.
        public var workers: Int = 10
        public init() {}
    }

    static func mb(_ bytes: Double?) -> Double { (bytes ?? 0) / 1_048_576 }

    /// Pages with no URL are not in any window (AppleScript sees far fewer tabs): automation.
    static func isHidden(_ t: Target) -> Bool { t.type == "page" && t.url.isEmpty }

    /// Pages Thermo never attaches to: browser UI, devtools.
    static func isInternal(_ url: String) -> Bool {
        ["chrome:", "chrome-untrusted:", "devtools:", "edge:", "brave:", "about:"].contains { url.hasPrefix($0) }
    }

    /// "x.com" from "https://x.com/home"; the URL itself when it has no host.
    public static func site(_ url: String) -> String {
        guard let host = URL(string: url)?.host else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Compares two samples (or reads one) into what to tell the user.
    public static func diagnose(_ after: Snapshot, before: Snapshot? = nil, limits: Limits = Limits()) -> Report {
        let earlier = Dictionary((before?.rows ?? []).map { ($0.targetId, $0) }, uniquingKeysWith: { a, _ in a })
        let seconds = before.map { after.date.timeIntervalSince($0.date) }.flatMap { $0 > 0 ? $0 : nil }
        var pages: [Page] = []
        var unmeasured = 0
        for t in after.rows where t.type == "page" && !isHidden(t) {
            guard let heap = t.heap else { unmeasured += 1; continue }
            var p = Page(id: t.targetId, url: t.url, title: t.title, heapMB: mb(heap),
                         nodes: Int(t.nodes ?? 0), listeners: Int(t.listeners ?? 0))
            if let seconds, let o = earlier[t.targetId], let oh = o.heap {
                let g = Growth(seconds: seconds, heapMB: mb(heap - oh), nodes: Int((t.nodes ?? 0) - (o.nodes ?? 0)),
                               listeners: Int((t.listeners ?? 0) - (o.listeners ?? 0)))
                p.growth = g
                p.leak = leak(g, limits)
                p.advice = p.leak.map { advice($0, g) }
            }
            pages.append(p)
        }
        pages.sort { $0.heapMB > $1.heapMB }

        // A listener leak is a certain bug; growth alone may still level off.
        let leaking = pages.filter { $0.leak != nil }
            .sorted { ($0.leak == .listeners ? 1 : 0, severity($0)) > ($1.leak == .listeners ? 1 : 0, severity($1)) }
        let largest = Array(pages.filter { $0.leak == nil }.prefix(5))

        // Same address open more than once (the fragment is part of the page in single-page apps).
        var byURL: [String: Duplicate] = [:]
        var order: [String] = []
        for t in after.rows where t.type == "page" && !isHidden(t) && !isInternal(t.url) {
            if byURL[t.url] == nil { order.append(t.url); byURL[t.url] = Duplicate(url: t.url, title: t.title, count: 0) }
            byURL[t.url]!.count += 1
        }
        let duplicates = order.compactMap { byURL[$0] }.filter { $0.count > 1 }.sorted { $0.count > $1.count }

        var bySite: [String: SiteWorkers] = [:]
        let workerRows = after.rows.filter { $0.type == "worker" || $0.type == "service_worker" }
        for w in workerRows {
            let s = site(w.url)
            bySite[s, default: SiteWorkers(site: s, count: 0, heapMB: 0)].count += 1
            bySite[s]!.heapMB += mb(w.heap)
        }
        // Only an address-less page that answered is real; unchecked ones are never counted.
        let realHidden = after.rows.filter { isHidden($0) && $0.ghost == false }
        let workers = bySite.values.filter { $0.count >= limits.workers }.sorted { ($0.count, $0.site) > ($1.count, $1.site) }

        return Report(sampled: after.date, seconds: seconds, pages: pages, leaking: leaking, largest: largest,
                      duplicates: duplicates, workers: workers,
                      hidden: realHidden.count, hiddenHeapMB: realHidden.reduce(0) { $0 + mb($1.heap) },
                      stale: after.rows.filter { isHidden($0) && $0.ghost != false }.count, unmeasured: unmeasured,
                      pagesHeapMB: pages.reduce(0) { $0 + $1.heapMB }, workersHeapMB: workerRows.reduce(0) { $0 + mb($1.heap) },
                      workerCount: workerRows.count)
    }

    static func leak(_ g: Growth, _ limits: Limits) -> Leak? {
        let perMinute = 60 / max(g.seconds, 1)
        if g.listeners >= limits.listeners && Double(g.nodes) < Double(g.listeners) / 10 { return .listeners }
        if g.heapMB >= limits.heapMinMB && g.heapMB * perMinute >= limits.heapMBPerMinute { return .heap }
        if Double(g.nodes) * perMinute >= limits.nodesPerMinute { return .nodes }
        return nil
    }

    static func severity(_ p: Page) -> Double {
        guard let g = p.growth else { return 0 }
        return g.heapMB + Double(g.listeners) / 100 + Double(g.nodes) / 1000
    }

    static func advice(_ leak: Leak, _ g: Growth) -> String {
        let secs = String(Int(g.seconds.rounded()))
        switch leak {
        case .listeners:
            return tr("It added %1$@ event listeners in %2$@ s while the page itself did not change: a leak in the page. Reloading it frees them; if it comes back, close it when you are not using it.",
                      String(g.listeners), secs)
        case .heap:
            return tr("Its memory grew %1$@ in %2$@ s. If it keeps growing, reload or close it.",
                      MemoryFormat.string(mebibytes: g.heapMB), secs)
        case .nodes:
            return tr("It keeps adding page elements (%1$@ in %2$@ s), like an endless feed. Reload it now and then.",
                      String(g.nodes), secs)
        }
    }

    /// Plain words on where the rest of Chrome's memory is, so the page numbers don't look wrong.
    public static func gapText(_ r: Report, appMemoryKB: Int?, gpuKB: Int?) -> String? {
        guard let total = appMemoryKB, total > 0 else { return nil }
        let pagesKB = Int((r.pagesHeapMB + r.workersHeapMB + r.hiddenHeapMB) * 1024)
        var text = tr("Pages' JavaScript uses %1$@ of the %2$@ the browser uses.", MachinePulse.gb(pagesKB), MachinePulse.gb(total))
        text += (text.hasSuffix("。") ? "" : " ") + (gpuKB.map { tr("The rest is the GPU process (%1$@), images, video and drawing, and extensions.", MachinePulse.gb($0)) }
            ?? tr("The rest is the GPU process, images, video and drawing, and extensions."))
        return text
    }

    // MARK: - Finding the browser

    /// Where to reach the browser's DevTools protocol: THERMO_CDP_URL, chrome-use's relay into the
    /// user's own Chrome, or a browser started with --remote-debugging-port (DevToolsActivePort).
    public static func endpoint(app: String = "Google Chrome", home: String = NSHomeDirectory(),
                                env: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let s = env["THERMO_CDP_URL"], let u = URL(string: s) { return u }
        if app == "Google Chrome",
           let s = try? String(contentsOfFile: home + "/.chrome-use/relay-cdp-url", encoding: .utf8),
           let u = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)), u.scheme?.hasPrefix("ws") == true {
            return u
        }
        guard let dir = profileDirs[app],
              let s = try? String(contentsOfFile: home + "/Library/Application Support/" + dir + "/DevToolsActivePort", encoding: .utf8)
        else { return nil }
        let lines = s.split(separator: "\n").map(String.init)
        guard lines.count >= 2, let port = Int(lines[0]) else { return nil }
        return URL(string: "ws://127.0.0.1:\(port)\(lines[1])")
    }

    /// Chromium browsers Thermo can look inside, by app name.
    public static let profileDirs: [String: String] = [
        "Google Chrome": "Google/Chrome", "Google Chrome Beta": "Google/Chrome Beta", "Google Chrome Canary": "Google/Chrome Canary",
        "Chromium": "Chromium", "Microsoft Edge": "Microsoft Edge", "Brave Browser": "BraveSoftware/Brave-Browser",
        "Vivaldi": "Vivaldi",
    ]

    public static func isBrowser(_ name: String) -> Bool { profileDirs[name] != nil }

    // MARK: - Sampling

    public enum Failure: Error, LocalizedError {
        case unreachable
        public var errorDescription: String? {
            tr("Could not reach the browser's DevTools connection.")
        }
    }

    /// Measures every page in a window (and every worker), a few at a time. `progress(done, total)`.
    public static func sample(_ endpoint: URL, progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> Snapshot {
        let cdp = CDP(endpoint)
        defer { cdp.close() }
        guard let infos = await cdp.send("Target.getTargets")?["targetInfos"] as? [[String: Any]] else { throw Failure.unreachable }
        let all: [Target] = infos.compactMap { i in
            guard let id = i["targetId"] as? String, let type = i["type"] as? String,
                  ["page", "worker", "service_worker"].contains(type) else { return nil }
            return Target(targetId: id, type: type, url: i["url"] as? String ?? "", title: i["title"] as? String ?? "",
                          attached: i["attached"] as? Bool)
        }
        // Address-less pages are checked too (are they pages at all?), never read.
        let measure = all.filter { !isInternal($0.url) }
        let skipped = all.filter { isInternal($0.url) }
        let counter = Counter()
        progress(0, measure.count)
        var rows: [Target] = skipped
        await withTaskGroup(of: Target.self) { group in
            var next = 0
            func add() {
                guard next < measure.count else { return }
                let t = measure[next]; next += 1
                group.addTask {
                    let r = await measureOne(t, cdp)
                    progress(counter.bump(), measure.count)
                    return r
                }
            }
            for _ in 0..<6 { add() }
            for await r in group { rows.append(r); add() }
        }
        return Snapshot(at: Date(), rows: rows)
    }

    static func measureOne(_ t: Target, _ cdp: CDP) async -> Target {
        var r = t
        guard let sid = await cdp.send("Target.attachToTarget", ["targetId": t.targetId, "flatten": true])?["sessionId"] as? String else {
            r.error = "attach refused"
            if isHidden(t) { r.ghost = true }
            return r
        }
        if isHidden(t) {
            // A relay can keep records of tabs long closed: attaching "works", evaluating says the
            // tab is gone. The cheapest possible question tells a ghost from a page.
            let (_, error) = await cdp.call("Runtime.evaluate", ["expression": "1", "returnByValue": true], session: sid)
            r.ghost = error != nil
            if let error { r.error = error }
            if r.ghost == true {
                _ = await cdp.send("Target.detachFromTarget", ["sessionId": sid])
                return r
            }
        }
        if t.type == "page" {
            _ = await cdp.send("Performance.enable", session: sid)
            let metrics = await cdp.send("Performance.getMetrics", session: sid)?["metrics"] as? [[String: Any]] ?? []
            for m in metrics {
                guard let v = (m["value"] as? NSNumber)?.doubleValue else { continue }
                switch m["name"] as? String {
                case "JSHeapUsedSize": r.heap = v
                case "Nodes": r.nodes = v
                case "JSEventListeners": r.listeners = v
                case "Documents": r.documents = v
                default: break
                }
            }
            _ = await cdp.send("Performance.disable", session: sid)
        } else if let h = await cdp.send("Runtime.getHeapUsage", session: sid) {
            r.heap = (h["usedSize"] as? NSNumber)?.doubleValue
        }
        _ = await cdp.send("Target.detachFromTarget", ["sessionId": sid])
        return r
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    }

    /// A minimal DevTools protocol client: one WebSocket, replies matched by id, 8 s per command.
    final class CDP: @unchecked Sendable {
        private let task: URLSessionWebSocketTask
        private let lock = NSLock()
        private var nextID = 0
        private var waiting: [Int: CheckedContinuation<[String: Any]?, Never>] = [:]

        init(_ url: URL) {
            task = URLSession.shared.webSocketTask(with: url)
            task.maximumMessageSize = 64 << 20
            task.resume()
            receive()
        }

        func close() {
            task.cancel(with: .normalClosure, reason: nil)
            lock.lock(); let all = waiting; waiting = [:]; lock.unlock()
            for c in all.values { c.resume(returning: nil) }
        }

        private func receive() {
            task.receive { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let message):
                    var data: Data?
                    switch message {
                    case .string(let s): data = s.data(using: .utf8)
                    case .data(let d): data = d
                    @unknown default: break
                    }
                    if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = obj["id"] as? Int {
                        if let e = obj["error"] as? [String: Any] {
                            self.finish(id, ["__error": e["message"] as? String ?? "error"])
                        } else {
                            self.finish(id, obj["result"] as? [String: Any] ?? [:])
                        }
                    }
                    self.receive()
                case .failure:
                    self.lock.lock(); let all = self.waiting; self.waiting = [:]; self.lock.unlock()
                    for c in all.values { c.resume(returning: nil) }
                }
            }
        }

        private func finish(_ id: Int, _ value: [String: Any]?) {
            lock.lock(); let c = waiting.removeValue(forKey: id); lock.unlock()
            c?.resume(returning: value)
        }

        /// The command's result, or nil on an error, a timeout or a closed connection.
        func send(_ method: String, _ params: [String: Any] = [:], session: String? = nil) async -> [String: Any]? {
            let (result, error) = await call(method, params, session: session)
            return error == nil ? result : nil
        }

        /// The result, or the error message ("timeout" when there was no answer).
        func call(_ method: String, _ params: [String: Any] = [:], session: String? = nil) async -> ([String: Any]?, String?) {
            guard let r = await raw(method, params, session: session) else { return (nil, "timeout") }
            if let e = r["__error"] as? String { return (nil, e) }
            return (r, nil)
        }

        private func raw(_ method: String, _ params: [String: Any] = [:], session: String? = nil) async -> [String: Any]? {
            await withCheckedContinuation { (c: CheckedContinuation<[String: Any]?, Never>) in
                lock.lock(); nextID += 1; let id = nextID; waiting[id] = c; lock.unlock()
                var msg: [String: Any] = ["id": id, "method": method, "params": params]
                if let session { msg["sessionId"] = session }
                guard let data = try? JSONSerialization.data(withJSONObject: msg), let s = String(data: data, encoding: .utf8) else {
                    return finish(id, nil)
                }
                task.send(.string(s)) { [weak self] error in if error != nil { self?.finish(id, nil) } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 8) { [weak self] in self?.finish(id, nil) }
            }
        }
    }

    // MARK: - Tabs without DevTools (AppleScript)

    /// A tab as the browser's windows show it.
    public struct Tab: Codable, Sendable, Equatable {
        public var window: Int
        public var index: Int
        public var url: String
        public var title: String
    }

    /// Every tab of every window, through the browser's AppleScript dictionary (no memory numbers).
    /// Nil when the browser is not running or Thermo may not control it.
    public static func tabs(app: String = "Google Chrome") -> [Tab]? {
        let script = """
        let app = null;
        try { app = Application(\(jsString(app))); } catch (e) {}
        if (!app || !app.running()) { '[]' } else {
          JSON.stringify(app.windows().map(w => [w.id(), w.tabs().map(t => [t.url(), t.title()])]));
        }
        """
        guard let out = osascript(script), let data = out.data(using: .utf8),
              let windows = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else { return nil }
        var tabs: [Tab] = []
        for w in windows {
            guard w.count == 2, let id = (w[0] as? NSNumber)?.intValue ?? (w[0] as? String).flatMap({ Int($0) }),
                  let list = w[1] as? [[Any]] else { continue }
            for (i, t) in list.enumerated() {
                tabs.append(Tab(window: id, index: i + 1, url: t.first as? String ?? "", title: t.count > 1 ? t[1] as? String ?? "" : ""))
            }
        }
        return tabs
    }

    /// Duplicates among AppleScript tabs.
    public static func duplicates(_ tabs: [Tab]) -> [Duplicate] {
        var counts: [String: Duplicate] = [:]
        var order: [String] = []
        for t in tabs where !isInternal(t.url) && !t.url.isEmpty {
            if counts[t.url] == nil { order.append(t.url); counts[t.url] = Duplicate(url: t.url, title: t.title, count: 0) }
            counts[t.url]!.count += 1
        }
        return order.compactMap { counts[$0] }.filter { $0.count > 1 }.sorted { $0.count > $1.count }
    }

    /// Closes one tab showing `url` (with `title`, when several match, the last of them).
    /// Only ever on the user's explicit confirmation.
    @discardableResult
    public static func close(url: String, title: String? = nil, app: String = "Google Chrome") -> Bool {
        let script = """
        const app = Application(\(jsString(app)));
        let hits = [];
        for (const w of app.windows()) for (const t of w.tabs()) if (t.url() === \(jsString(url))) hits.push(t);
        const exact = hits.filter(t => t.title() === \(jsString(title ?? "")));
        const pick = (exact.length ? exact : hits).pop();
        if (pick) { pick.close(); 'closed' } else { 'none' }
        """
        return osascript(script) == "closed"
    }

    static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    static func osascript(_ script: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-l", "JavaScript", "-e", script]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - One diagnosis, for the CLI and the app

    public struct Diagnosis: Codable, Sendable, Equatable {
        public enum Mode: String, Codable, Sendable {
            /// Memory per page through DevTools.
            case devtools
            /// Only the tab list (AppleScript): titles, addresses, duplicates.
            case tabs
            /// Neither worked (the browser is not running, or Thermo may not control it).
            case unavailable
        }
        public var app: String
        public var mode: Mode
        public var report: Report?
        public var tabs: [Tab]?
        public var duplicates: [Duplicate]
        /// "N hidden pages (likely automation) …"
        public var hiddenText: String?
        /// Where the rest of the browser's memory is.
        public var gap: String?
        /// How to get more (install or reconnect chrome-use).
        public var hint: String?
    }

    public enum Phase: Sendable, Equatable {
        case measuring(round: Int, done: Int, total: Int)
        case waiting(secondsLeft: Int)
        case listingTabs
    }

    /// Said once wherever pages are measured.
    public static var debuggingBarNote: String {
        tr("While measuring, Chrome briefly shows \"is being debugged\" at the top; it goes away when Thermo is done.")
    }

    public static let chromeUseInstall = "curl -fsSL https://raw.githubusercontent.com/leeguooooo/chrome-use/main/install.sh | sh"

    /// Samples (twice, `watch` seconds apart, when given), else falls back to the tab list.
    /// `measure` attaches a debugger to each page, which briefly shows Chrome's "is being debugged"
    /// bar; only when the user asked for it. Without it, just the tab list (nothing is attached).
    public static func diagnose(app: String = "Google Chrome", measure: Bool = true, watch: TimeInterval?, appMemoryKB: Int? = nil, gpuKB: Int? = nil,
                                home: String = NSHomeDirectory(),
                                progress: @escaping @Sendable (Phase) -> Void = { _ in }) async -> Diagnosis {
        var hint: String?
        if !measure {
            if endpoint(app: app, home: home) == nil {
                hint = app == "Google Chrome"
                    ? tr("To see memory per page (which one leaks), install chrome-use, which connects Thermo to your own Chrome: %1$@", chromeUseInstall)
                    : tr("To see memory per page, start %1$@ with --remote-debugging-port=9222.", app)
            }
        } else if let url = endpoint(app: app, home: home) {
            do {
                let first = try await sample(url) { d, t in progress(.measuring(round: 1, done: d, total: t)) }
                var report = diagnose(first)
                // A relay that has not reconnected yet (Chrome just reopened) lists no pages while
                // the windows have tabs: that is not "0 pages".
                if report.pages.isEmpty, let tabs = tabs(app: app), !tabs.isEmpty { throw Failure.unreachable }
                if let watch, watch > 0 {
                    var left = Int(watch.rounded())
                    while left > 0 {
                        progress(.waiting(secondsLeft: left))
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        left -= 1
                        if Task.isCancelled { break }
                    }
                    let second = try await sample(url) { d, t in progress(.measuring(round: 2, done: d, total: t)) }
                    report = diagnose(second, before: first)
                }
                return diagnosis(report, app: app, appMemoryKB: appMemoryKB, gpuKB: gpuKB)
            } catch {
                hint = app == "Google Chrome"
                    ? tr("chrome-use is not connected yet (after Chrome reopens, its extension takes a few seconds to reconnect). Try again shortly; if it stays like this, run `chrome-use reconnect`.")
                    : tr("The browser's DevTools connection did not answer.")
            }
        } else if app == "Google Chrome" {
            hint = tr("To see memory per page (which one leaks), install chrome-use, which connects Thermo to your own Chrome: %1$@", chromeUseInstall)
        } else {
            hint = tr("To see memory per page, start %1$@ with --remote-debugging-port=9222.", app)
        }
        progress(.listingTabs)
        guard let tabs = tabs(app: app) else {
            return Diagnosis(app: app, mode: .unavailable, report: nil, tabs: nil, duplicates: [], hiddenText: nil, gap: nil,
                             hint: (hint.map { $0 + ($0.hasSuffix("。") ? "" : " ") } ?? "") + tr("Thermo could not list the tabs either: allow it in System Settings → Privacy & Security → Automation."))
        }
        return Diagnosis(app: app, mode: .tabs, report: nil, tabs: tabs, duplicates: duplicates(tabs), hiddenText: nil, gap: nil, hint: hint)
    }

    /// A DevTools report as a diagnosis (also for saved samples).
    public static func diagnosis(_ report: Report, app: String, appMemoryKB: Int?, gpuKB: Int?) -> Diagnosis {
        Diagnosis(app: app, mode: .devtools, report: report, tabs: nil, duplicates: report.duplicates,
                  hiddenText: hiddenText(report, app: app),
                  gap: gapText(report, appMemoryKB: appMemoryKB, gpuKB: gpuKB), hint: nil)
    }

    /// Address-less targets in plain words: dead relay records, and real pages in no window.
    public static func hiddenText(_ r: Report, app: String) -> String? {
        var parts: [String] = []
        if r.stale > 0 {
            parts.append(tr("%1$@ stale chrome-use records (not real pages, no memory): reload or update the chrome-use extension to clear them.",
                            String(r.stale)))
        }
        if r.hidden > 0 {
            parts.append(tr("%1$@ pages in no window (likely automation tools), %2$@ of JavaScript.",
                            String(r.hidden), MemoryFormat.string(mebibytes: r.hiddenHeapMB)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
