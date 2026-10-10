import XCTest
@testable import CleanKit
import ThermoL10n

/// Numbers from two real samples 90 s apart (a Mac with Chrome at 20 GB), addresses made generic.
final class ChromeInspectorTests: XCTestCase {
    typealias T = ChromeInspector.Target
    let mb = 1_048_576.0

    override func setUp() { L10n.override = .english }
    override func tearDown() { L10n.override = nil }

    func testSaysItInChinese() {
        L10n.override = .simplifiedChinese
        let (a, b) = samples()
        let r = ChromeInspector.diagnose(b, before: a)
        XCTAssertEqual(r.leaking[0].advice, "90 秒里加了 411 个事件监听，页面本身却没变：这是页面的泄漏。刷新一下就能释放；如果又涨回来，不用时就关掉它。")
        XCTAssertTrue(ChromeInspector.hiddenText(135, app: "Google Chrome").contains("重启 Google Chrome 会一起清掉"))
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
        before += (0..<135).map { T(targetId: "hidden\($0)", type: "page", url: "", title: "", attached: true) }
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
        XCTAssertEqual(r.hidden, 135)
        XCTAssertEqual(r.unmeasured, 1)  // chrome://settings
        XCTAssertEqual(r.pages.count, 6)
        let d = ChromeInspector.diagnosis(r, app: "Google Chrome", appMemoryKB: 20 * 1_048_576, gpuKB: 2_621_440)
        XCTAssertTrue(d.hiddenText!.hasPrefix("135 hidden pages"))
        XCTAssertTrue(d.hiddenText!.contains("Restarting Google Chrome"))
        XCTAssertTrue(d.gap!.contains("of the 20.0 GB"))
        XCTAssertTrue(d.gap!.contains("GPU process (2.5 GB)"))
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
        XCTAssertEqual(ChromeInspector.diagnose(s).hidden, 1)
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
}
