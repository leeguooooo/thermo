import Foundation
import ThermoL10n

/// Chat and work apps keep years of media in their own containers. Thermo cannot tell which of it
/// you still want, so these are shown for what they cost, with where to clear them in the app.
enum AppData {
    struct App {
        let id: String
        let name: String
        let paths: [String]
        let processNames: [String]
        let howTo: String
    }

    static let apps: [App] = [
        App(id: "lark", name: "Lark / Feishu", paths: ["~/Library/Application Support/LarkInternational", "~/Library/Application Support/Feishu",
                                                       "~/Library/Containers/com.bytedance.macos.feishu", "~/Library/Containers/com.electron.lark"],
            processNames: ["Lark", "Feishu"], howTo: "Settings → General → Storage → Clear cache"),
        App(id: "wechat", name: "WeChat", paths: ["~/Library/Containers/com.tencent.xinWeChat"],
            processNames: ["WeChat"], howTo: "Settings → Storage → Manage"),
        App(id: "whatsapp", name: "WhatsApp", paths: ["~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared"],
            processNames: ["WhatsApp"], howTo: "Settings → Storage → Manage storage"),
        App(id: "telegram", name: "Telegram", paths: ["~/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram",
                                                      "~/Library/Containers/ru.keepcoder.Telegram"],
            processNames: ["Telegram"], howTo: "Settings → Data and Storage → Storage Usage → Clear"),
        App(id: "slack", name: "Slack", paths: ["~/Library/Containers/com.tinyspeck.slackmacgap", "~/Library/Application Support/Slack"],
            processNames: ["Slack"], howTo: "Help → Troubleshooting → Clear Cache and Restart"),
        App(id: "discord", name: "Discord", paths: ["~/Library/Application Support/discord"],
            processNames: ["Discord"], howTo: "quit Discord; its cache is rebuilt"),
        App(id: "qq", name: "QQ", paths: ["~/Library/Containers/com.tencent.qq"],
            processNames: ["QQ"], howTo: "Settings → Storage → Clear"),
        App(id: "wecom", name: "WeCom", paths: ["~/Library/Containers/com.tencent.WeWorkMac"],
            processNames: ["企业微信", "WeCom"], howTo: "Settings → Storage → Clear"),
        App(id: "dingtalk", name: "DingTalk", paths: ["~/Library/Containers/com.alibaba.DingTalkMac", "~/Library/Application Support/DingTalkMac"],
            processNames: ["DingTalk"], howTo: "Settings → General → Clear cache"),
    ]

    /// Only worth a line above this size.
    static let minimum: Int64 = 1_000_000_000

    static func scan(_ ctx: ScanContext) -> [CleanItem] {
        // Tens of GB in up to 100,000 files per app: measured side by side. Private sizes, not used
        // space: WhatsApp's 12 GB on disk frees 4 GB (its media is hard-linked and cloned).
        let present = apps.map { app in (app, app.paths.map(ctx.path).filter(FS.exists)) }.filter { !$0.1.isEmpty }
        let containers = ctx.path("~/Library/Containers")
        let extras = FS.children(containers).filter {
            let n = ($0 as NSString).lastPathComponent
            return n.hasPrefix("com.tencent.xinWeChat") && n != "com.tencent.xinWeChat"
        }
        let jobs = present.flatMap { $0.1 } + extras
        var sizes = [TreeSize](repeating: TreeSize(), count: jobs.count)
        let lock = NSLock()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = ctx.options.lowPriority ? .background : .utility
        for (i, path) in jobs.enumerated() {
            queue.addOperation {
                guard ScanCancellation.current?.isCancelled != true else { return }
                let s = FS.size(path, trackNewest: true)
                lock.lock(); sizes[i] = s; lock.unlock()
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        let measured = Dictionary(zip(jobs, sizes), uniquingKeysWith: { a, _ in a })

        var out: [CleanItem] = []
        for (app, roots) in present {
            let size = roots.reduce(TreeSize()) { $0 + (measured[$1] ?? TreeSize()) }
            guard size.bytes >= minimum else { continue }
            out.append(CleanItem(id: "app-data/\(app.id)", category: .system, title: tr("%1$@ data", app.name),
                                 detail: roots.count == 1 ? ctx.tilde(roots[0]) : tr("%1$@ and %2$@ more", ctx.tilde(roots[0]), String(roots.count - 1)),
                                 safety: .review, bytes: size.bytes, files: size.files, lastUsed: size.newest,
                                 note: tr("chat history and media; Thermo does not delete it"),
                                 hint: tr("in %1$@: %2$@", app.name, tr(app.howTo))))
        }
        // Copies of a chat app's container made by automation tools (e.g. a second WeChat sandbox).
        for c in extras {
            let n = (c as NSString).lastPathComponent
            let size = measured[c] ?? TreeSize()
            guard size.bytes >= minimum else { continue }
            out.append(CleanItem(id: "app-data/\(n)", category: .system, title: tr("Extra WeChat sandbox · %1$@", n),
                                 detail: ctx.tilde(c), safety: .review, bytes: size.bytes, files: size.files, lastUsed: size.newest,
                                 note: tr("a second WeChat container, usually made by an automation tool; remove it from that tool"),
                                 hint: tr("remove it with the tool that created it")))
        }
        return out
    }
}
