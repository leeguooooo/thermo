import Foundation

/// chrome-use 1.5.186+ answers "which page is the problem" itself (`chrome-use diag pages`, JSON
/// schema 1): the tab list without attaching anything, and per page memory only when asked
/// (`--measure --force`, or `--watch N --force` for two samples and a leak class). Thermo prefers
/// it to its own DevTools connection, which stays for older chrome-use.
extension ChromeInspector {
    /// The schema-1 object, only the keys Thermo reads (others are ignored; keys are only ever added).
    public struct ChromeUseReport: Decodable, Sendable {
        public struct Connection: Decodable, Sendable { public var state: String? }
        public struct Extension: Decodable, Sendable {
            public var version: String?
            public var behindPublished: Bool?
            public var hint: String?
        }
        public struct Metrics: Decodable, Sendable {
            public var JSHeapUsedSize: Double?
            public var Nodes: Double?
            public var JSEventListeners: Double?
        }
        public struct Delta: Decodable, Sendable {
            public var seconds: Double?
            public var JSHeapUsedSize: Double?
            public var Nodes: Double?
            public var JSEventListeners: Double?
        }
        public struct Measure: Decodable, Sendable { public var status: String?; public var reason: String? }
        public struct Page: Decodable, Sendable {
            public var handle: String
            public var windowId: Int?
            public var index: Int?
            public var title: String?
            public var url: String?
            public var discarded: Bool?
            public var metrics: Metrics?
            public var measure: Measure?
            public var delta: Delta?
            public var leakClass: String?
        }
        public struct WorkerSite: Decodable, Sendable { public var site: String; public var count: Int; public var usedSize: Double? }
        public struct Workers: Decodable, Sendable { public var total: Int?; public var sites: [WorkerSite]? }

        public var schema: Int
        public var exitCode: Int?
        public var exitReason: String?
        public var generatedAt: Double?
        public var connection: Connection?
        public var `extension`: Extension?
        public var staleRelayRecords: Int?
        public var pages: [Page]
        public var workers: Workers?
    }

    /// Where chrome-use is, if it is new enough to have `diag pages` (1.5.186).
    public static func chromeUseDiagTool(env: [String: String] = ProcessInfo.processInfo.environment,
                                         home: String = NSHomeDirectory()) -> String? {
        let dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init)
            + [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        guard let path = dirs.map({ $0 + "/chrome-use" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              let out = run(path, ["--version"], timeout: 10)?.output,
              let version = out.split(separator: " ").last.map({ String($0).trimmingCharacters(in: .whitespacesAndNewlines) }),
              versionAtLeast(version, "1.5.186") else { return nil }
        return path
    }

    static func versionAtLeast(_ v: String, _ min: String) -> Bool {
        let a = v.split(separator: ".").map { Int($0) ?? 0 }, b = min.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }

    /// Runs a command; nil when it could not start or ran past `timeout`.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> (output: String, status: Int32)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return (String(decoding: data, as: UTF8.self), p.terminationStatus)
    }

    /// One `chrome-use diag pages` run. `measure` adds `--measure --force` (each tab not held by
    /// chrome-use is attached, measured and released, never activated); `watch` samples twice.
    static func chromeUseDiag(_ tool: String, measure: Bool, watch: TimeInterval?) -> ChromeUseReport? {
        var args = ["diag", "pages", "--json", "--limit", "1000"]
        if let watch, watch > 0 { args += ["--watch", String(Int(watch.rounded())), "--force"] } else if measure { args += ["--measure", "--force"] }
        guard let r = run(tool, args, timeout: (watch ?? 0) + 240),
              let report = try? JSONDecoder().decode(ChromeUseReport.self, from: Data(r.output.utf8)), report.schema == 1
        else { return nil }
        return report
    }

    /// Schema-1 rows as the tab list (what Thermo shows before anything is measured).
    public static func tabs(_ r: ChromeUseReport) -> [Tab] {
        r.pages.map { Tab(window: $0.windowId ?? 0, index: ($0.index ?? 0) + 1, url: $0.url ?? "", title: $0.title ?? "") }
    }

    /// Schema-1 measurements as Thermo's report; chrome-use's own leak class decides what is growing.
    public static func report(_ r: ChromeUseReport, limits: Limits = Limits()) -> Report {
        let mb = 1_048_576.0
        var pages: [Page] = []
        var unmeasured = 0
        for row in r.pages {
            guard let m = row.metrics, let heap = m.JSHeapUsedSize else { unmeasured += 1; continue }
            var p = Page(id: row.handle, url: row.url ?? "", title: row.title ?? "", heapMB: heap / mb,
                         nodes: Int(m.Nodes ?? 0), listeners: Int(m.JSEventListeners ?? 0))
            if let d = row.delta, let s = d.seconds, s > 0 {
                let g = Growth(seconds: s, heapMB: (d.JSHeapUsedSize ?? 0) / mb, nodes: Int(d.Nodes ?? 0), listeners: Int(d.JSEventListeners ?? 0))
                p.growth = g
                switch row.leakClass {
                case "listeners_growing_nodes_flat": p.leak = .listeners
                case "heap_growing": p.leak = .heap
                case "nodes_climbing": p.leak = .nodes
                default: p.leak = nil
                }
                p.advice = p.leak.map { advice($0, g) }
            }
            pages.append(p)
        }
        pages.sort { $0.heapMB > $1.heapMB }
        let leaking = pages.filter { $0.leak != nil }
            .sorted { ($0.leak == .listeners ? 1 : 0, severity($0)) > ($1.leak == .listeners ? 1 : 0, severity($1)) }
        let seconds = pages.compactMap { $0.growth?.seconds }.max()
        let sites = (r.workers?.sites ?? []).map { SiteWorkers(site: site($0.site), count: $0.count, heapMB: ($0.usedSize ?? 0) / mb) }
        return Report(sampled: r.generatedAt.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date(), seconds: seconds,
                      pages: pages, leaking: leaking, largest: Array(pages.filter { $0.leak == nil }.prefix(5)),
                      duplicates: duplicates(tabs(r)),
                      workers: sites.filter { $0.count >= limits.workers }.sorted { ($0.count, $0.site) > ($1.count, $1.site) },
                      hidden: 0, hiddenHeapMB: 0, stale: r.staleRelayRecords ?? 0, unmeasured: unmeasured,
                      pagesHeapMB: pages.reduce(0) { $0 + $1.heapMB }, workersHeapMB: sites.reduce(0) { $0 + $1.heapMB },
                      workerCount: r.workers?.total ?? 0)
    }

    /// The extension's own advice when it is behind (chrome-use words it).
    static func extensionHint(_ r: ChromeUseReport) -> String? {
        guard let e = r.extension, e.behindPublished == true || e.hint != nil else { return nil }
        return e.hint.map { tr("chrome-use's Chrome extension needs attention: %1$@", $0) }
    }

    /// The whole check through chrome-use. Nil when its answer could not be read (then the raw
    /// DevTools path or the AppleScript tab list takes over).
    static func diagnoseWithChromeUse(_ tool: String, app: String, measure: Bool, watch: TimeInterval?, appMemoryKB: Int?, gpuKB: Int?,
                                      progress: @escaping @Sendable (Phase) -> Void) async -> Diagnosis? {
        let measuring = measure || (watch ?? 0) > 0
        // chrome-use reports nothing until it is done; count down the interval meanwhile.
        let ticker = Task {
            guard let watch, watch > 0 else { progress(measuring ? .measuring(round: 1, done: 0, total: 0) : .listingTabs); return }
            var left = Int(watch.rounded())
            while left > 0, !Task.isCancelled {
                progress(.waiting(secondsLeft: left))
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                left -= 1
            }
            if !Task.isCancelled { progress(.measuring(round: 2, done: 0, total: 0)) }
        }
        let r = await Task.detached { chromeUseDiag(tool, measure: measure, watch: watch) }.value
        ticker.cancel()
        guard let r else { return nil }
        if r.exitCode == 2 || r.exitReason == "not_connected" {
            // Not connected (Chrome just reopened, or the extension is off): say so, list tabs plainly.
            let notConnected = tr("chrome-use is not connected yet (after Chrome reopens, its extension takes a few seconds to reconnect). Try again shortly; if it stays like this, run `chrome-use reconnect`.")
            progress(.listingTabs)
            guard let t = tabs(app: app) else { return Diagnosis(app: app, mode: .unavailable, duplicates: [], hint: notConnected) }
            return Diagnosis(app: app, mode: .tabs, report: nil, tabs: t, duplicates: duplicates(t), hiddenText: nil, gap: nil, hint: notConnected)
        }
        let staleText = (r.staleRelayRecords ?? 0) > 0
            ? tr("%1$@ stale chrome-use records (not real pages, no memory): reload or update the chrome-use extension to clear them.", String(r.staleRelayRecords!))
            : nil
        let hint = [extensionHint(r), r.exitReason == "held_by_other_session" ? tr("Every page is in use by another chrome-use session right now; try again when it is done.") : nil]
            .compactMap { $0 }.joined(separator: " ")
        if !measuring {
            let t = tabs(r)
            return Diagnosis(app: app, mode: .tabs, report: nil, tabs: t, duplicates: duplicates(t), hiddenText: staleText, gap: nil,
                             hint: hint.isEmpty ? nil : hint)
        }
        let rep = report(r)
        var d = diagnosis(rep, app: app, appMemoryKB: appMemoryKB, gpuKB: gpuKB)
        d.hint = hint.isEmpty ? nil : hint
        return d
    }
}
