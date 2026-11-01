import AppKit
import CloudDriveKit
import SwiftUI
import XCTest
@testable import ThermoApp

private final class ChromeMemoryBackend: YunXSecretBackend, @unchecked Sendable {
    private var data: Data?
    func read() throws -> Data? { data }
    func write(_ data: Data) throws { self.data = data }
}

/// Writes the page and prompt to `YUNX_SHOT_DIR`; skipped otherwise. Real AppKit drawing, no Keychain.
@MainActor
final class YunXScreenshots: XCTestCase {
    private func shot<V: View>(_ view: V, _ name: String, _ size: CGSize, dark: Bool, dir: String) {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = host.appearance
        window.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name)-\(dark ? "dark" : "light").png"))
        window.close()
    }

    func testRender() throws {
        guard let dir = ProcessInfo.processInfo.environment["YUNX_SHOT_DIR"] else { throw XCTSkip("no YUNX_SHOT_DIR") }
        func model() -> YunXDownloadModel {
            YunXDownloadModel(vault: YunXVault(backend: ChromeMemoryBackend()),
                              settingsStore: YunXSettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!, trackers: ChromeMemoryBackend()),
                              jobStore: YunXJobStore(backend: ChromeMemoryBackend()), drives: CloudDriveRegistry(providers: []))
        }
        let files = [DriveFile(id: "d", name: "第二季 全集", size: 0, isDirectory: true, parentId: ""),
                     DriveFile(id: "a", name: "S02E01.2160p.WEB-DL.H265.mkv", size: 4_812_000_000, isDirectory: false, parentId: ""),
                     DriveFile(id: "b", name: "S02E02.2160p.WEB-DL.H265.mkv", size: 4_630_000_000, isDirectory: false, parentId: ""),
                     DriveFile(id: "c", name: "字幕.zip", size: 18_400_000, isDirectory: false, parentId: "")]
        var run = YunXJob(id: UUID(), name: "S02E01.2160p.WEB-DL.H265.mkv", relativeName: "第二季 全集/S02E01.2160p.WEB-DL.H265.mkv", saveDirectory: "/tmp/d", received: 1_900_000_000, total: 4_812_000_000, speed: 18_400_000, state: .running)
        run.canPause = true
        let wait = YunXJob(id: UUID(), name: "S02E02.2160p.WEB-DL.H265.mkv", relativeName: "第二季 全集/S02E02.2160p.WEB-DL.H265.mkv", saveDirectory: "/tmp/d", total: 4_630_000_000, state: .queued)
        let done = YunXJob(id: UUID(), name: "字幕.zip", relativeName: "字幕.zip", saveDirectory: "/tmp/d", received: 18_400_000, total: 18_400_000, state: .finished(URL(fileURLWithPath: "/tmp/z")))
        let bad = YunXJob(id: UUID(), name: "花絮.mp4", relativeName: "花絮.mp4", saveDirectory: "/tmp/d", state: .failed("分享已失效"))
        let accounts = [YunXAccount(id: "1", platform: "quark", fields: ["nickname": "LEO"], updatedAt: 1, isPrimary: true)]
        let size = CGSize(width: 900, height: 680)
        let ready = YunXChromeUseSetup(detect: { .init(tool: "/x", connected: true) })
        for dark in [true, false] {
            func page(_ m: YunXDownloadModel, _ s: YunXChromeUseSetup = ready) -> some View { YunXDownloadPage(model: m, setup: s).background(Theme.canvas) }
            let empty = model()
            shot(page(empty), "page-empty", size, dark: dark, dir: dir)
            let missing = YunXChromeUseSetup(detect: { .init() })
            let wait2 = expectation(description: "probe"); Task { await missing.refresh(); wait2.fulfill() }; self.wait(for: [wait2], timeout: 5)
            shot(page(model(), missing), "page-needs-chrome-use", size, dark: dark, dir: dir)
            let resolved = model(); resolved.link = "https://pan.quark.cn/s/1a2b3c4d"
            resolved.loadPageForTesting(files: files, path: ["美剧合集", "第二季"]); resolved.selected = ["a", "c"]
            shot(page(resolved), "page-resolved", size, dark: dark, dir: dir)
            let active = model(); active.link = "https://pan.quark.cn/s/1a2b3c4d"
            active.loadPageForTesting(files: files, path: ["美剧合集"], jobs: [run, wait, done, bad])
            shot(page(active), "page-downloading", CGSize(width: 900, height: 760), dark: dark, dir: dir)
            let acc = model(); acc.loadPageForTesting(accounts: accounts)
            shot(YunXAccountsSheet(model: acc, setup: ready), "accounts", CGSize(width: 640, height: 560), dark: dark, dir: dir)
            shot(YunXSettingsSheet(model: model()), "settings", CGSize(width: 520, height: 640), dark: dark, dir: dir)
            let hit = try XCTUnwrap(YunXClipboardDetector.detect("https://pan.quark.cn/s/1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d"))
            shot(YunXClipboardPromptView(hit: hit, ignore: {}, open: {}).padding(16).background(dark ? Color(white: 0.2) : Color(white: 0.9)), "prompt", CGSize(width: 420, height: 120), dark: dark, dir: dir)
        }
    }
}
