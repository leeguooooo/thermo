import AppKit
import CloudDriveKit
import DownloadKit
import Foundation
import ThermoL10n
import VideoKit

/// A supported link found on the clipboard, without the text around it.
struct YunXClipboardHit: Equatable {
    enum Kind: Equatable {
        case share(DrivePlatform)
        case video(VideoPlatform)
        case magnet
        case ed2k
    }

    let kind: Kind
    let link: String
    let passcode: String?

    var title: String {
        switch kind {
        case let .share(platform): return tr("Found %1$@ share link", YunXNames.drive(platform))
        case let .video(platform): return tr("Found %1$@ video link", platform.displayName)
        case .magnet: return tr("Found a magnet link")
        case .ed2k: return tr("Found an ed2k link")
        }
    }

    var symbol: String {
        switch kind {
        case .share: return "cloud"
        case .video: return "play.rectangle"
        case .magnet, .ed2k: return "link"
        }
    }
}

/// Finds the first supported link in copied text. `YunXLink.classify` decides what a link is; this
/// only cuts candidates out of the text and refuses a host that merely mentions a supported site.
enum YunXClipboardDetector {
    /// Share messages are short; a huge copy is not worth scanning on the main thread.
    static let maxScannedLength = 16_384

    private static let candidates = try! NSRegularExpression(pattern:
        #"(?<![A-Za-z0-9])(?:magnet:\?\S+|ed2k://\|[^\r\n]*?\|/|https?://[^\s\u3000-\u303F\u4E00-\u9FFF\uFF00-\uFFEF<>]+)"#,
        options: .caseInsensitive)
    private static let hosts = try! NSRegularExpression(pattern: "^(?:" + [
        #"pan\.quark\.cn"#, #"drive\.uc\.cn"#, #"pan\.xunlei\.com"#, #"yun\.139\.com"#,
        #"(?:.+\.)?123(?:865|pan)\.(?:com|cn)"#, #"(?:.+\.)?115(?:cdn|rc)?\.com"#, #"(?:.+\.)?guangyapan\.com"#,
        #"(?:.+\.)?(?:ilanzou|lanzou[a-z0-9-]*|lan[zs]o[ux])\.(?:com|net|org|cn)"#,
        #"(?:.+\.)?(?:douyin|iesdouyin|xiaohongshu|kuaishou|chenzhongtech|weibo|bilibili)\.com"#,
        #"(?:.+\.)?(?:xhslink\.(?:com|cn)|weibo\.cn|acfun\.cn|b23\.tv|bili2233\.cn|pixiv\.net)"#,
    ].joined(separator: "|") + ")$", options: .caseInsensitive)
    private static let trailing = Set(".!?:。，,；;)]}\"'、！？…")

    static func detect(_ text: String) -> YunXClipboardHit? {
        let scanned = String(text.prefix(maxScannedLength))
        let matches = candidates.matches(in: scanned, range: NSRange(scanned.startIndex..., in: scanned))
        for match in matches {
            guard let range = Range(match.range, in: scanned) else { continue }
            var link = String(scanned[range])
            if !link.lowercased().hasPrefix("ed2k:") {
                while let last = link.last, trailing.contains(last) { link.removeLast() }
            }
            if let hit = hit(link, in: scanned) { return hit }
        }
        return nil
    }

    private static func hit(_ link: String, in text: String) -> YunXClipboardHit? {
        switch YunXLink.classify(link) {
        case .p2p:
            if Ed2kLink.isEd2k(link) { return YunXClipboardHit(kind: .ed2k, link: link, passcode: nil) }
            guard link.range(of: "xt=urn:", options: .caseInsensitive) != nil else { return nil }
            return YunXClipboardHit(kind: .magnet, link: link, passcode: nil)
        case let .share(parsed):
            guard allowedHost(link) else { return nil }
            return YunXClipboardHit(kind: .share(parsed.platform), link: link,
                                    passcode: parsed.passcode ?? ShareLinkRouter.textPasscode(in: text))
        case let .video(detected):
            guard allowedHost(link) else { return nil }
            return YunXClipboardHit(kind: .video(detected.platform), link: link, passcode: nil)
        case nil:
            return nil
        }
    }

    private static func allowedHost(_ link: String) -> Bool {
        guard let host = URLComponents(string: link)?.host else { return false }
        return hosts.firstMatch(in: host, range: NSRange(host.startIndex..., in: host)) != nil
    }
}

/// The few pasteboard calls the watcher makes, so it can be tested without the real one.
@MainActor protocol YunXClipboardSource {
    var changeCount: Int { get }
    /// Reading types leaves the copied content untouched.
    var types: [String] { get }
    func string() -> String?
}

@MainActor struct YunXSystemClipboard: YunXClipboardSource {
    var changeCount: Int { NSPasteboard.general.changeCount }
    var types: [String] { NSPasteboard.general.types?.map(\.rawValue) ?? [] }
    func string() -> String? { NSPasteboard.general.string(forType: .string) }
}

/// YunX's rules: only a change counts, the same link is not offered twice in a row, and a link seen
/// while prompting is unwanted (Thermo focused, or a prompt already up) is dropped, not queued.
/// Everything here stays in memory, and only the extracted link is kept.
@MainActor final class YunXClipboardWatcher {
    /// nspasteboard.org markers that password managers and clipboard tools set.
    static let skippedTypes: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]
    private static let maxIgnored = 64

    private let source: any YunXClipboardSource
    private let canPrompt: () -> Bool
    private let present: (YunXClipboardHit) -> Void
    private var lastChange: Int
    private var lastLink: String?
    private var ignored: [String] = []

    init(source: any YunXClipboardSource, canPrompt: @escaping () -> Bool, present: @escaping (YunXClipboardHit) -> Void) {
        self.source = source
        self.canPrompt = canPrompt
        self.present = present
        lastChange = source.changeCount
    }

    /// What is already on the clipboard is not news: called on starting, and on turning the setting back on.
    func rebaseline() { lastChange = source.changeCount }

    func poll() {
        let change = source.changeCount
        guard change != lastChange else { return }
        lastChange = change
        guard Self.skippedTypes.isDisjoint(with: source.types), let text = source.string() else { return }
        let hit = YunXClipboardDetector.detect(text)
        let repeated = hit?.link == lastLink
        lastLink = hit?.link
        guard let hit, !repeated, !ignored.contains(hit.link), canPrompt() else { return }
        present(hit)
    }

    /// Lasts until Thermo quits.
    func ignore(_ link: String) {
        guard !ignored.contains(link) else { return }
        ignored.append(link)
        if ignored.count > Self.maxIgnored { ignored.removeFirst() }
    }
}

enum YunXClipboardSetting {
    /// Separate from `YunXSettings`, whose store reads the Keychain and is too heavy for launch.
    static let key = "yunx.clipboardPrompt"
    static func enabled(_ defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: key) as? Bool ?? true }
}
