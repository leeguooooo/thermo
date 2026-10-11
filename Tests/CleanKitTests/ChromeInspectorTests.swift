import XCTest
@testable import CleanKit
import ThermoL10n

/// Numbers from two real samples 90 s apart (a Mac with Chrome at 20 GB), addresses made generic.
final class ChromeInspectorTests: XCTestCase {
    typealias T = ChromeInspector.Target
    let mb = 1_048_576.0

    override func setUp() { L10n.override = .english }
    override func tearDown() { L10n.override = nil }

    @MainActor func testCancelledDiagnosisDoesNotFallBackToBrowserScripts() async {
        let task = Task { await ChromeInspector.diagnose(app: "Fixture Browser", measure: false, watch: nil) }
        task.cancel()
        let diagnosis = await task.value
        XCTAssertEqual(diagnosis.mode, .unavailable)
        XCTAssertEqual(diagnosis.hint, "Check stopped. You can start again when ready.")
    }

    func testSaysItInChinese() {
        L10n.override = .simplifiedChinese
        let (a, b) = samples()
        let r = ChromeInspector.diagnose(b, before: a)
        XCTAssertEqual(r.leaking[0].advice, "90 秒里增加了 411 个事件监听，节点数变化不大。这可能是监听器泄漏，请刷新后重新检查。")
        XCTAssertTrue(ChromeInspector.hiddenText(r, app: "Google Chrome")!.hasPrefix("136 条 chrome-use 残留记录"))
    }

    func page(_ id: String, _ url: String, _ title: String, heapMB: Double?, nodes: Double = 0, listeners: Double = 0) -> T {
        T(targetId: id, type: "page", url: url, title: title, attached: true,
          heap: heapMB.map { $0 * mb }, nodes: nodes, listeners: listeners, documents: 1)
    }

    func samples() -> (ChromeInspector.Snapshot, ChromeInspector.Snapshot) {
        let t0 = Date(timeIntervalSince1970: 1_791_647_250)
        var before: [T] = [
            page("admin", "https://admin.example.com/#init-config", "City config", heapMB: 41.9, nodes: 578, listeners: 3000),
            page("x1", "https://x.com/home", "Home / X", heapMB: 100.0, nodes: 6600, listeners: 5000),
            page("x2", "https://x.com/home", "Home / X", heapMB: 92.6, nodes: 3420, listeners: 4000),
            page("x3", "https://x.com/home", "Home / X", heapMB: 60, nodes: 2000, listeners: 1000),
            page("studio", "https://studio.example.com/channel", "Studio", heapMB: 130.0, nodes: 23485, listeners: 900),
            page("feed", "https://feed.example.com/", "Feed", heapMB: 20, nodes: 1000, listeners: 100),
            page("ext", "chrome://settings", "Settings", heapMB: nil),
        ]
        // Dead chrome-use relay records (attach works, evaluating says the tab is gone) …
        before += (0..<135).map { T(targetId: "ghost\($0)", type: "page", url: "", title: "", attached: true, error: "stale sessionId", ghost: true) }
        // … two real pages in no window, and one never checked.
        before += (0..<2).map { T(targetId: "auto\($0)", type: "page", url: "", title: "", attached: true, heap: 30 * 1_048_576, ghost: false) }
        before.append(T(targetId: "unchecked", type: "page", url: "", title: ""))
        before += (0..<78).map { T(targetId: "w\($0)", type: "worker", url: "https://www.tiktok.com/static/media-decoder.worker.js",
                                   title: "", heap: $0 < 10 ? 2 * 1_048_576 : nil) }
        before += (0..<3).map { T(targetId: "s\($0)", type: "service_worker", url: "https://docs.example.com/sw.js", title: "") }
        var after = before
        func bump(_ id: String, heapMB: Double = 0, nodes: Double = 0, listeners: Double = 0) {
            let i = after.firstIndex { $0.targetId == id }!
            after[i].heap! += heapMB * mb; after[i].nodes! += nodes; after[i].listeners! += listeners
        }
        bump("admin", heapMB: -0.1, listeners: 411)          // listeners pile up, page unchanged
        bump("x1", heapMB: 3.9, nodes: 100, listeners: 264)  // memory climbing
        bump("x2", heapMB: 3.6, nodes: 90, listeners: 146)
        bump("studio", heapMB: 0.1)                          // big but flat
        bump("feed", nodes: 2000)                            // endless feed
        return (.init(at: t0, rows: before), .init(at: t0.addingTimeInterval(90), rows: after))
    }

    func testFlagsListenerLeaksFirstThenGrowingMemoryAndNodes() {
        let (a, b) = samples()
        let r = ChromeInspector.diagnose(b, before: a)
        XCTAssertEqual(r.seconds, 90)
        XCTAssertEqual(r.leaking.map(\.id), ["admin", "x1", "x2", "feed"])
        XCTAssertEqual(r.leaking.map(\.leak), [.listeners, .heap, .heap, .nodes])
        XCTAssertEqual(r.leaking[0].growth?.listeners, 411)
        XCTAssertTrue(r.leaking[0].advice!.contains("411 event listeners"))
        // Big but not growing: listed as largest, never as leaking.
        XCTAssertEqual(r.largest.first?.id, "studio")
        XCTAssertNil(r.largest.first?.leak)
    }

    func testDuplicatesWorkersHiddenAndUnmeasured() {
        let (a, b) = samples()
        let r = ChromeInspector.diagnose(b, before: a)
        XCTAssertEqual(r.duplicates, [.init(url: "https://x.com/home", title: "Home / X", count: 3)])
        XCTAssertEqual(r.workers.map(\.site), ["tiktok.com"])
        XCTAssertEqual(r.workers.first?.count, 78)
        XCTAssertEqual(r.workers.first?.heapMB ?? 0, 20, accuracy: 0.01)
        XCTAssertEqual(r.workerCount, 81)
        XCTAssertEqual(r.stale, 136, "ghosts and unchecked ones are never pages")
        XCTAssertEqual(r.hidden, 2)
        XCTAssertEqual(r.hiddenHeapMB, 60, accuracy: 0.01)
        XCTAssertEqual(r.unmeasured, 1)  // chrome://settings
        XCTAssertEqual(r.pages.count, 6)
        let d = ChromeInspector.diagnosis(r, app: "Google Chrome", appMemoryKB: 20 * 1_048_576, gpuKB: 2_621_440)
        XCTAssertTrue(d.hiddenText!.hasPrefix("136 stale chrome-use records (not real pages, no memory)"))
        XCTAssertTrue(d.hiddenText!.contains("2 pages in no window"))
        XCTAssertFalse(d.hiddenText!.contains("Restart"), "restarting the browser does not clear relay records")
        XCTAssertTrue(d.gap!.contains("of the 20.0 GiB"))
        XCTAssertTrue(d.gap!.contains("GPU process (2.5 GiB)"))
    }

    func testOneSampleListsButDoesNotGuessLeaks() {
        let (_, b) = samples()
        let r = ChromeInspector.diagnose(b)
        XCTAssertNil(r.seconds)
        XCTAssertTrue(r.leaking.isEmpty)
        XCTAssertTrue(r.pages.allSatisfy { $0.growth == nil })
        XCTAssertEqual(r.largest.first?.id, "studio")
    }

    func testDecodesTheProbeDump() throws {
        let json = #"{"at":1791647250703,"rows":[{"targetId":"A","type":"page","url":"https://x.com/home","title":"X","attached":true,"Documents":3,"Frames":4,"JSEventListeners":383,"Nodes":1515,"JSHeapUsedSize":43971876,"JSHeapTotalSize":47054848},{"targetId":"B","type":"page","url":"","title":"","attached":true}]}"#
        let s = try JSONDecoder().decode(ChromeInspector.Snapshot.self, from: Data(json.utf8))
        XCTAssertEqual(s.rows.count, 2)
        XCTAssertEqual(s.rows[0].listeners, 383)
        XCTAssertEqual(s.rows[0].heap, 43_971_876)
        XCTAssertEqual(s.date.timeIntervalSince1970, 1_791_647_250.703, accuracy: 0.001)
        XCTAssertEqual(ChromeInspector.diagnose(s).stale, 1)
        XCTAssertEqual(ChromeInspector.diagnose(s).hidden, 0)
    }

    func testFindsTheRelayOrADebuggingPort() throws {
        let home = NSTemporaryDirectory() + "chrome-endpoint-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: home) }
        XCTAssertNil(ChromeInspector.endpoint(app: "Google Chrome", home: home, env: [:]))
        try FileManager.default.createDirectory(atPath: home + "/.chrome-use", withIntermediateDirectories: true)
        try "ws://127.0.0.1:53545/abc\n".write(toFile: home + "/.chrome-use/relay-cdp-url", atomically: true, encoding: .utf8)
        XCTAssertEqual(ChromeInspector.endpoint(app: "Google Chrome", home: home, env: [:])?.absoluteString, "ws://127.0.0.1:53545/abc")
        // The relay is Chrome's only; other browsers need their own debugging port.
        XCTAssertNil(ChromeInspector.endpoint(app: "Microsoft Edge", home: home, env: [:]))
        let edge = home + "/Library/Application Support/Microsoft Edge"
        try FileManager.default.createDirectory(atPath: edge, withIntermediateDirectories: true)
        try "9222\n/devtools/browser/xyz\n".write(toFile: edge + "/DevToolsActivePort", atomically: true, encoding: .utf8)
        XCTAssertEqual(ChromeInspector.endpoint(app: "Microsoft Edge", home: home, env: [:])?.absoluteString, "ws://127.0.0.1:9222/devtools/browser/xyz")
        XCTAssertEqual(ChromeInspector.endpoint(app: "Microsoft Edge", home: home, env: ["THERMO_CDP_URL": "ws://h:1/p"])?.absoluteString, "ws://h:1/p")
    }

    func testTabDuplicatesAndScriptQuoting() {
        let tabs: [ChromeInspector.Tab] = [
            .init(window: 1, index: 1, url: "https://a.com/", title: "A"), .init(window: 2, index: 1, url: "https://a.com/", title: "A"),
            .init(window: 2, index: 2, url: "chrome://newtab/", title: "New Tab"), .init(window: 2, index: 3, url: "chrome://newtab/", title: "New Tab"),
            .init(window: 2, index: 4, url: "https://b.com/", title: "B"),
        ]
        XCTAssertEqual(ChromeInspector.duplicates(tabs), [.init(url: "https://a.com/", title: "A", count: 2)])
        XCTAssertEqual(ChromeInspector.jsString(#"he said "hi" \ ok"#), #""he said \"hi\" \\ ok""#)
        XCTAssertEqual(ChromeInspector.site("https://www.tiktok.com/x"), "tiktok.com")
    }

    // MARK: restart only promises what was checked

    func writeChrome(_ home: String, restore: [String: Int?], active: [String]) throws {
        let root = home + "/Library/Application Support/Google/Chrome"
        for (profile, value) in restore {
            try FileManager.default.createDirectory(atPath: root + "/" + profile, withIntermediateDirectories: true)
            let prefs: [String: Any] = value.map { ["session": ["restore_on_startup": $0]] } ?? ["session": [String: Any]()]
            try JSONSerialization.data(withJSONObject: prefs).write(to: URL(fileURLWithPath: root + "/" + profile + "/Preferences"))
        }
        try JSONSerialization.data(withJSONObject: ["profile": ["last_active_profiles": active]])
            .write(to: URL(fileURLWithPath: root + "/Local State"))
    }

    func testRestoresOnlyWhenEveryOpenProfileContinuesWhereItLeftOff() throws {
        let home = NSTemporaryDirectory() + "chrome-restore-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: home) }
        // Nothing to read: not checked, so no promise.
        XCTAssertEqual(BrowserSession.windows(for: "Google Chrome", home: home), .thermoReopensTabs)
        try writeChrome(home, restore: ["Default": nil], active: ["Default"])  // "Open the New Tab page"
        XCTAssertEqual(BrowserSession.windows(for: "Google Chrome", home: home), .thermoReopensTabs)
        try writeChrome(home, restore: ["Default": 1, "Profile 2": 5], active: ["Default", "Profile 2"])
        XCTAssertFalse(BrowserSession.restoresSession("Google Chrome", home: home))
        try writeChrome(home, restore: ["Default": 1, "Profile 2": 1], active: ["Default", "Profile 2"])
        XCTAssertEqual(BrowserSession.windows(for: "Google Chrome", home: home), .restoresItself)
        XCTAssertEqual(BrowserSession.windows(for: "Slack", home: home), .unknown)
    }

    func testRestartNotesAndSavedTabs() {
        XCTAssertEqual(MachinePulse.restartNote(.unknown), "Save your work first: it may not reopen its windows.")
        XCTAssertTrue(MachinePulse.restartNote(.thermoReopensTabs).contains("Thermo saves them"))
        let tabs: [ChromeInspector.Tab] = [
            .init(window: 7, index: 1, url: "https://a.com/", title: "A"), .init(window: 3, index: 1, url: "https://b.com/", title: "B"),
            .init(window: 7, index: 2, url: "https://c.com/", title: "C"), .init(window: 3, index: 2, url: "", title: ""),
        ]
        XCTAssertEqual(BrowserSession.group(tabs), [["https://a.com/", "https://c.com/"], ["https://b.com/"]])
        L10n.override = .simplifiedChinese
        XCTAssertEqual(MachinePulse.sentences("重启它大约能腾出 19 GB。", "它会自己恢复标签页。"), "重启它大约能腾出 19 GB。它会自己恢复标签页。")
    }
}

/// chrome-use `diag pages` (schema 1) read into Thermo's report.
final class ChromeUseDiagTests: XCTestCase {
    override func setUp() { L10n.override = .english }
    override func tearDown() { L10n.override = nil }

    let watched = #"""
    {"schema":1,"command":"diag pages","success":true,"exitCode":0,"exitReason":null,"generatedAt":1791647340000,
     "connection":{"transport":"relay","state":"connected","extensionConnected":true},
     "extension":{"applies":true,"version":"0.5.33","behindPublished":true,"hint":"update ab-connect to 0.5.35 in chrome://extensions"},
     "staleRelayRecords":4,
     "pages":[
      {"handle":"chrome-tab:1","windowId":7,"index":0,"title":"City config","url":"https://admin.example.com/#init","discarded":false,
       "metrics":{"JSHeapUsedSize":43835408,"Nodes":578,"JSEventListeners":3411,"Documents":1},
       "measure":{"status":"measured","via":"temporary_attach","forced":true},
       "delta":{"seconds":90,"JSHeapUsedSize":-101284,"Nodes":0,"JSEventListeners":411},"leakClass":"listeners_growing_nodes_flat"},
      {"handle":"chrome-tab:2","windowId":7,"index":1,"title":"Home / X","url":"https://x.com/home",
       "metrics":{"JSHeapUsedSize":108801916,"Nodes":6701,"JSEventListeners":5264},
       "measure":{"status":"measured"},"delta":{"seconds":90,"JSHeapUsedSize":4129104,"Nodes":100,"JSEventListeners":264},"leakClass":"heap_growing"},
      {"handle":"chrome-tab:3","windowId":9,"index":0,"title":"Home / X","url":"https://x.com/home",
       "metrics":{"JSHeapUsedSize":136155928,"Nodes":23485,"JSEventListeners":900},
       "measure":{"status":"measured"},"delta":{"seconds":90,"JSHeapUsedSize":117376,"Nodes":0,"JSEventListeners":0},"leakClass":"none"},
      {"handle":"chrome-tab:4","windowId":9,"index":1,"title":"Old tab","url":"https://old.example.com/","discarded":true,
       "metrics":null,"measure":{"status":"skipped","reason":"discarded"}}
     ],
     "workers":{"source":"relay_records","total":80,"measured":10,"measuredHeap":true,
       "sites":[{"site":"https://www.tiktok.com","count":78,"usedSize":20971520},{"site":"https://github.com","count":2,"usedSize":null}]}}
    """#

    func decode(_ s: String) throws -> ChromeInspector.ChromeUseReport {
        try JSONDecoder().decode(ChromeInspector.ChromeUseReport.self, from: Data(s.utf8))
    }

    func testWatchedRunBecomesThermosReport() throws {
        let r = ChromeInspector.report(try decode(watched))
        XCTAssertEqual(r.leaking.map(\.id), ["chrome-tab:1", "chrome-tab:2"])
        XCTAssertEqual(r.leaking.map(\.leak), [.listeners, .heap])
        XCTAssertEqual(r.leaking[0].growth?.listeners, 411)
        XCTAssertTrue(r.leaking[0].advice!.contains("411 event listeners in 90 s"))
        XCTAssertEqual(r.largest.first?.id, "chrome-tab:3")
        XCTAssertEqual(r.seconds, 90)
        XCTAssertEqual(r.unmeasured, 1, "the discarded tab is never attached")
        XCTAssertEqual(r.stale, 4)
        XCTAssertEqual(r.duplicates, [.init(url: "https://x.com/home", title: "Home / X", count: 2)])
        XCTAssertEqual(r.workers.map(\.site), ["tiktok.com"])
        XCTAssertEqual(r.workers.first?.heapMB ?? 0, 20, accuracy: 0.01)
        XCTAssertEqual(r.workerCount, 80)
    }

    func testListOnlyRunGivesTabsAndExtensionAdvice() throws {
        let d = try decode(watched)
        XCTAssertEqual(ChromeInspector.tabs(d).map(\.window), [7, 7, 9, 9])
        XCTAssertEqual(ChromeInspector.tabs(d).map(\.index), [1, 2, 1, 2])
        XCTAssertEqual(ChromeInspector.extensionHint(d), "chrome-use's Chrome extension needs attention: update ab-connect to 0.5.35 in chrome://extensions")
    }

    func testNotConnectedAndNewerKeysAreRead() throws {
        let d = try decode(#"{"schema":1,"exitCode":2,"exitReason":"not_connected","pages":[],"someFutureKey":{"x":1}}"#)
        XCTAssertEqual(d.exitCode, 2)
        XCTAssertTrue(d.pages.isEmpty)
        XCTAssertNil(ChromeInspector.extensionHint(d))
    }

    func testVersionGate() {
        XCTAssertTrue(ChromeInspector.versionAtLeast("1.5.186", "1.5.186"))
        XCTAssertTrue(ChromeInspector.versionAtLeast("1.6.0", "1.5.186"))
        XCTAssertFalse(ChromeInspector.versionAtLeast("1.5.183", "1.5.186"))
    }
}
