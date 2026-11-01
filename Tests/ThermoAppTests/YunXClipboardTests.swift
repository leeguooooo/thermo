import ThermoL10n
import XCTest
@testable import ThermoApp

@MainActor private final class FakeClipboard: YunXClipboardSource {
    var changeCount = 0
    var types = ["public.utf8-plain-text"]
    var text: String?
    var reads = 0
    func string() -> String? { reads += 1; return text }
    func copy(_ text: String, types: [String] = ["public.utf8-plain-text"]) {
        self.text = text; self.types = types; changeCount += 1
    }
}

@MainActor final class YunXClipboardTests: XCTestCase {
    private let quark = "https://pan.quark.cn/s/abc123"

    private func make() -> (FakeClipboard, YunXClipboardWatcher, () -> [String]) {
        let board = FakeClipboard()
        var shown: [String] = []
        let watcher = YunXClipboardWatcher(source: board, canPrompt: { true }, present: { shown.append($0.link) })
        return (board, watcher, { shown })
    }

    func testDetectsEachDriveVideoPlatformAndP2PLink() throws {
        let drives = ["https://pan.quark.cn/s/a1", "https://drive.uc.cn/s/a1", "https://pan.xunlei.com/s/a1",
                      "https://yun.139.com/shareweb/#/w/i/a1", "https://www.123pan.com/s/a1-b2", "https://115.com/s/swabc123",
                      "https://www.guangyapan.com/s/a1", "https://www.ilanzou.com/s/a1", "https://www.lanzoui.com/a1"]
        for link in drives { guard case .share = YunXClipboardDetector.detect(link)?.kind else { return XCTFail(link) } }
        let videos = ["https://v.douyin.com/abc", "https://xhslink.com/abc", "https://v.kuaishou.com/abc", "https://weibo.com/123/AbCdEfG",
                      "https://www.acfun.cn/v/ac123", "https://www.bilibili.com/video/BV1xx411c7mD", "https://www.pixiv.net/artworks/123"]
        for link in videos { guard case .video = YunXClipboardDetector.detect(link)?.kind else { return XCTFail(link) } }
        let hash = String(repeating: "a", count: 40)
        XCTAssertEqual(YunXClipboardDetector.detect("magnet:?xt=urn:btih:\(hash)")?.kind, .magnet)
        XCTAssertEqual(YunXClipboardDetector.detect("ed2k://|file|a b.mkv|12|\(String(repeating: "0", count: 32))|/")?.link,
                       "ed2k://|file|a b.mkv|12|\(String(repeating: "0", count: 32))|/")
    }

    func testTitleNamesTheDrive() throws {
        let saved = L10n.override
        defer { L10n.override = saved }
        L10n.override = .simplifiedChinese
        XCTAssertEqual(try XCTUnwrap(YunXClipboardDetector.detect(quark)).title, "发现夸克网盘分享链接")
    }

    func testExtractsLinkAndPasscodeFromSurroundingText() {
        let hit = YunXClipboardDetector.detect("电影合集：\(quark)提取码：a1b2，快存。")
        XCTAssertEqual(hit?.link, quark)
        XCTAssertEqual(hit?.passcode, "a1b2")
        XCTAssertEqual(YunXClipboardDetector.detect("see https://example.com/page then \(quark).")?.link, quark)
        let magnet = "magnet:?xt=urn:btih:\(String(repeating: "b", count: 40))"
        XCTAssertEqual(YunXClipboardDetector.detect("下载 \(magnet) 谢谢")?.link, magnet)
    }

    func testShowsNothingForUnsupportedLinks() {
        for text in ["hello", "https://example.com/s/abc", "https://evil.com/pan.quark.cn/s/abc", "https://pan.quark.cn.evil.com/s/abc",
                     "https://google.com/search?q=https://www.bilibili.com/video/BV1xx411c7mD", "movie.torrent", "magnet:?dn=x", "pan.quark.cn/s/abc",
                     "https://evil.com/?u=magnet:?xt=urn:btih:abc"] {
            XCTAssertNil(YunXClipboardDetector.detect(text), text)
        }
    }

    func testReadsOnlyWhenChangeCountMoves() {
        let (board, watcher, shown) = make()
        board.text = quark
        watcher.poll(); watcher.poll()
        XCTAssertEqual(board.reads, 0)
        XCTAssertEqual(shown(), [])
        board.copy(quark)
        watcher.poll(); watcher.poll()
        XCTAssertEqual(board.reads, 1)
        XCTAssertEqual(shown(), [quark])
    }

    func testDedupesRepeatsButNotAfterSomethingElse() {
        let (board, watcher, shown) = make()
        board.copy(quark); watcher.poll()
        board.copy("看这个 \(quark)"); watcher.poll()
        XCTAssertEqual(shown(), [quark])
        board.copy("other"); watcher.poll()
        board.copy(quark); watcher.poll()
        XCTAssertEqual(shown(), [quark, quark])
    }

    func testIgnoredLinkStaysQuiet() {
        let (board, watcher, shown) = make()
        board.copy(quark); watcher.poll()
        watcher.ignore(quark)
        board.copy("other"); watcher.poll()
        board.copy(quark); watcher.poll()
        XCTAssertEqual(shown(), [quark])
    }

    func testConcealedAndTransientAreNeverRead() {
        let (board, watcher, shown) = make()
        for type in YunXClipboardWatcher.skippedTypes {
            board.copy(quark, types: ["public.utf8-plain-text", type]); watcher.poll()
        }
        XCTAssertEqual(board.reads, 0)
        XCTAssertEqual(shown(), [])
    }

    func testLinkSeenWhileBusyIsDroppedAndRebaselineSkipsOldContent() {
        let board = FakeClipboard()
        var allowed = false
        var shown = 0
        let watcher = YunXClipboardWatcher(source: board, canPrompt: { allowed }, present: { _ in shown += 1 })
        board.copy(quark); watcher.poll()
        allowed = true
        watcher.poll()
        XCTAssertEqual(shown, 0)
        board.copy("https://pan.quark.cn/s/other")
        watcher.rebaseline(); watcher.poll()
        XCTAssertEqual(board.reads, 1)
        XCTAssertEqual(shown, 0)
    }

    func testSettingDefaultsOn() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "YunXClipboardTests"))
        defaults.removePersistentDomain(forName: "YunXClipboardTests")
        XCTAssertTrue(YunXClipboardSetting.enabled(defaults))
        defaults.set(false, forKey: YunXClipboardSetting.key)
        XCTAssertFalse(YunXClipboardSetting.enabled(defaults))
    }
}
