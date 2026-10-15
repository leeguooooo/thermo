import AgentCore
import Foundation
import ThermoL10n

/// An app bundle found in /Applications or ~/Applications.
public struct InstalledApp: Codable, Identifiable, Sendable, Equatable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var bundleID: String?
    public var version: String?
    /// Size of the bundle itself (0 until measured).
    public var bytes: Int64 = 0
    /// Files the app keeps in the home folder, found by bundle ID and name (empty until looked up).
    public var leftovers: [AppLeftover] = []
    /// Why Thermo will not uninstall it (system app, password manager, VPN, input method, …).
    public var protected: String?
    /// The Homebrew cask that installed it.
    public var cask: String?

    public var leftoverBytes: Int64 { leftovers.reduce(0) { $0 + $1.bytes } }
    public var totalBytes: Int64 { bytes + leftoverBytes }

    public init(path: String, name: String, bundleID: String?, version: String? = nil) {
        self.path = path; self.name = name; self.bundleID = bundleID; self.version = version
    }
}

public struct AppLeftover: Codable, Sendable, Equatable, Hashable {
    public var path: String
    public var bytes: Int64
    /// Newest modification inside it.
    public var lastUsed: Date?
    /// A browser profile, chat history or mailbox: kept unless asked for.
    public var personal: Bool?

    public init(path: String, bytes: Int64, lastUsed: Date? = nil, personal: Bool? = nil) {
        self.path = path; self.bytes = bytes; self.lastUsed = lastUsed; self.personal = personal
    }
}

/// Data an app left behind after it was deleted, grouped by its bundle ID.
public struct OrphanData: Codable, Identifiable, Sendable, Equatable {
    public var id: String { bundleID }
    public var bundleID: String
    public var items: [AppLeftover]

    public init(bundleID: String, items: [AppLeftover]) { self.bundleID = bundleID; self.items = items }
    public var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    public var lastUsed: Date? { items.compactMap(\.lastUsed).max() }
}

/// What an uninstall will do, shown in full before anything moves.
public struct UninstallPlan: Codable, Sendable {
    public var app: InstalledApp
    /// Everything that goes to the Trash: the bundle first, then its leftovers.
    public var paths: [String]
    public var bytes: Int64
    /// Set when it cannot be uninstalled now.
    public var blocked: String?
    /// Installer packages that put files outside the home folder; Thermo leaves those.
    public var receipts: [String] = []
    /// Personal data left in place (profiles, chat history, mail), unless the plan includes it.
    public var kept: [AppLeftover]?
}

public enum AppUninstaller {
    // MARK: - Finding apps

    public static func appDirs(home: String = NSHomeDirectory()) -> [String] {
        ["/Applications", "/Applications/Utilities", home + "/Applications"]
    }

    /// Apps in /Applications and ~/Applications, read from their Info.plist, sorted by name. Sizes are not measured.
    public static func installed(home: String = NSHomeDirectory(), dirs: [String]? = nil) -> [InstalledApp] {
        let fm = FileManager.default
        var seen = Set<String>()
        var apps: [InstalledApp] = []
        for dir in dirs ?? appDirs(home: home) {
            var bundles: [String] = []
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where !name.hasPrefix(".") {
                let path = dir + "/" + name
                if name.hasSuffix(".app") { bundles.append(path); continue }
                // Suites keep their apps one folder down ("Adobe Photoshop 2025/Adobe Photoshop 2025.app").
                guard dir != "/Applications/Utilities", FS.isDirectory(path) else { continue }
                bundles += ((try? fm.contentsOfDirectory(atPath: path)) ?? []).filter { $0.hasSuffix(".app") }.map { path + "/" + $0 }
            }
            for path in bundles {
                guard seen.insert(path).inserted, var app = read(path) else { continue }
                app.protected = protection(app, home: home)
                app.cask = cask(for: app)
                apps.append(app)
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func read(_ path: String) -> InstalledApp? {
        let plist = path + "/Contents/Info.plist"
        guard let data = FileManager.default.contents(atPath: plist),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            // A bundle without a readable Info.plist is still an app the user can see and remove.
            guard FS.exists(path) else { return nil }
            return InstalledApp(path: path, name: ((path as NSString).lastPathComponent as NSString).deletingPathExtension, bundleID: nil)
        }
        let file = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let id = (info["CFBundleIdentifier"] as? String).flatMap { isBundleID($0) ? $0 : nil }
        return InstalledApp(path: path, name: file, bundleID: id,
                            version: (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String))
    }

    /// Measures every app and looks up its leftovers, several at a time; `each` hears about each one
    /// as it finishes (from any thread).
    public static func measure(_ apps: [InstalledApp], home: String = NSHomeDirectory(), cancellation: ScanCancellation? = nil,
                               each: ((InstalledApp) -> Void)? = nil) -> [InstalledApp] {
        var out = apps
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            if cancellation?.isCancelled == true { return }
            var app = apps[i]
            app.bytes = bundleSize(app.path, cancellation: cancellation)
            app.leftovers = leftovers(for: app, installed: apps, home: home)
            lock.lock(); out[i] = app; lock.unlock()
            each?(app)
        }
        return out
    }

    /// The bundle's size as Finder shows it. Browsers keep their versions as clones, so the private
    /// bytes alone (what disk cleanup reports) can be a few megabytes for a gigabyte app.
    public static func bundleSize(_ path: String, cancellation: ScanCancellation? = nil) -> Int64 {
        let size = FS.size(path, cancellation: cancellation)
        return max(size.bytes, size.allocated)
    }

    /// Finds apps by file name, display name or bundle ID, ignoring case.
    public static func find(_ query: String, in apps: [InstalledApp]) -> [InstalledApp] {
        let q = query.hasSuffix(".app") ? String(query.dropLast(4)) : query
        let exact = apps.filter {
            $0.name.caseInsensitiveCompare(q) == .orderedSame || $0.bundleID?.caseInsensitiveCompare(q) == .orderedSame || $0.path == query
        }
        if !exact.isEmpty { return exact }
        let n = normalized(q)
        guard !n.isEmpty else { return [] }
        return apps.filter { normalized($0.name).contains(n) }
    }

    // MARK: - Protection

    /// Apple apps that come from the App Store or developer.apple.com and may be removed.
    static let appleRemovable = ["com.apple.dt.", "com.apple.FinalCut", "com.apple.Motion", "com.apple.Compressor",
                                 "com.apple.logic", "com.apple.garageband", "com.apple.iMovie", "com.apple.iWork.",
                                 "com.apple.MainStage", "com.apple.Playgrounds"]

    /// Bundle IDs whose data must never be treated as removable leftovers, and whose apps Thermo will
    /// not uninstall: password managers, VPN and proxy clients, input methods, security and MDM agents.
    /// Matched case-insensitively; `*` stands for anything.
    static let protectedPatterns = [
        // password managers and keys
        "com.1password.*", "com.agilebits.*", "com.lastpass.*", "com.dashlane.*", "com.bitwarden.*",
        "com.keepassx.*", "org.keepassx.*", "org.keepassxc.*", "com.authy.*", "com.yubico.*",
        // input methods
        "*inputmethod*", "*.ime", "*.ime.*", "com.googlecode.rimeime.*", "im.rime.*",
        // VPN and proxy clients
        "*vpn*", "*clash*", "*surge*", "*mihomo*", "*shadowsocks*", "*v2ray*", "*v2box*", "*nekoray*",
        "*sing-box*", "*hiddify*", "*quantumult*", "com.qiuyuzhou.*", "*tailscale*", "*zerotier*",
        "*wireguard*", "*cloudflare*warp*", "*1dot1dot1dot1*", "*amnezia*", "*mullvad*", "*windscribe*",
        "*surfshark*", "*privateinternetaccess*",
        // security and device management: these have their own uninstallers
        "com.crowdstrike.*", "com.sentinelone.*", "com.sentinel-labs.*", "com.eset.*", "com.jamf.*",
        "com.jamfsoftware.*", "com.paloaltonetworks.*", "com.cisco.anyconnect*", "com.cisco.secureclient*",
        // Thermo itself
        "dev.thermo*",
    ]

    /// Why `app` must not be uninstalled, or nil.
    public static func protection(_ app: InstalledApp, home: String = NSHomeDirectory()) -> String? {
        let location = Guard.deletionLocation(app.path)
        if location.hasPrefix("/System/") { return tr("part of macOS") }
        if let id = app.bundleID {
            if id.hasPrefix("com.apple."), !appleRemovable.contains(where: { id.hasPrefix($0) }) { return tr("part of macOS") }
            if id.lowercased().hasPrefix("dev.thermo") { return tr("this is Thermo") }
            if protectedPatterns.contains(where: { matches(id.lowercased(), $0) }) { return tr("protected: password manager, VPN, input method or security software") }
        }
        let n = app.name.lowercased()
        if ["1password", "bitwarden", "keychain"].contains(where: n.contains) || n.contains("vpn") {
            return tr("protected: password manager, VPN, input method or security software")
        }
        return nil
    }

    public static func isProtected(_ bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        if id.hasPrefix("com.apple.") { return true }
        return protectedPatterns.contains { matches(id, $0) }
    }

    /// Glob with `*` only, on lowercased text.
    static func matches(_ s: String, _ pattern: String) -> Bool {
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1 else { return s == pattern }
        guard s.hasPrefix(parts[0]) else { return false }
        var rest = Substring(s.dropFirst(parts[0].count))
        for (i, part) in parts.dropFirst().enumerated() {
            let last = i == parts.count - 2
            if part.isEmpty { continue }
            if last { return rest.hasSuffix(part) }
            guard let r = rest.range(of: part) else { return false }
            rest = rest[r.upperBound...]
        }
        return true
    }

    /// Reverse-DNS: at least three parts of letters, digits, `-` and `_`. Anything else (slashes,
    /// globs, `..`) never reaches a path.
    public static func isBundleID(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, s.count <= 255 else { return false }
        return parts.allSatisfy { p in
            !p.isEmpty && p.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }

    static func normalized(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// `name` is `id`, or `id` followed by `.` or `-` and more (`com.foo.app.helper`, `com.foo.app-1.plist`).
    static func startsWith(_ name: String, id: String) -> Bool {
        let n = name.lowercased(), i = id.lowercased()
        guard n.hasPrefix(i) else { return false }
        if n.count == i.count { return true }
        let next = n[n.index(n.startIndex, offsetBy: i.count)]
        return next == "." || next == "-"
    }

    // MARK: - Homebrew and installer packages

    public static let caskrooms = ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"]

    /// The Homebrew cask that installed `app`, read from Homebrew's own records.
    public static func cask(for app: InstalledApp, caskrooms: [String] = caskrooms) -> String? {
        let fm = FileManager.default
        let file = (app.path as NSString).lastPathComponent
        for room in caskrooms {
            for token in (try? fm.contentsOfDirectory(atPath: room)) ?? [] where !token.hasPrefix(".") {
                let meta = room + "/" + token + "/.metadata"
                guard let walker = fm.enumerator(atPath: meta) else { continue }
                for case let rel as String in walker where rel.hasSuffix(".json") || rel.hasSuffix(".rb") {
                    guard rel.contains("Casks/"), let text = try? String(contentsOfFile: meta + "/" + rel, encoding: .utf8) else { continue }
                    if text.contains("\"" + file + "\"") || text.contains("'" + file + "'") { return token }
                }
            }
        }
        return nil
    }

    /// Installer package receipts named after the bundle ID.
    public static func receipts(for bundleID: String?, dir: String = "/var/db/receipts") -> [String] {
        guard let id = bundleID else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasSuffix(".plist") }
            .map { String($0.dropLast(6)) }
            .filter { startsWith($0, id: id) }
            .sorted()
    }

    // MARK: - Leftovers

    /// Folders named after a whole product family or shared by many tools; never taken for one app's data.
    static let sharedNames: Set<String> = ["google", "microsoft", "adobe", "jetbrains", "apple", "mozilla", "docker",
                                           "local", "code", "chrome", "electron", "python", "node", "java", "git",
                                           "homebrew", "cloudkit", "icloud", "crashreporter", "caches", "logs"]

    /// Files `app` keeps in the home folder that exist now. Name-based places are skipped when another
    /// installed app shares the name, and Group Containers when another app shares the bundle ID prefix.
    public static func leftovers(for app: InstalledApp, installed: [InstalledApp], home: String = NSHomeDirectory()) -> [AppLeftover] {
        candidates(for: app, installed: installed, home: home).compactMap { path in
            var st = stat()
            guard lstat(path, &st) == 0 else { return nil }
            let size = FS.size(path, trackNewest: true)
            return AppLeftover(path: path, bytes: size.bytes, lastUsed: size.newest,
                               personal: isPersonal(path, bundleID: app.bundleID, home: home) ? true : nil)
        }
    }

    static func candidates(for app: InstalledApp, installed: [InstalledApp], home: String) -> [String] {
        let lib = home + "/Library"
        var out: [String] = []
        let others = installed.filter { $0.path != app.path }
        let otherNames = Set(others.map { normalized($0.name) })

        // Names: "Maestro Studio" → MaestroStudio, Maestro_Studio, Maestro-Studio, and lowercase forms.
        let name = app.name
        let n = normalized(name)
        if name.count >= 3, !sharedNames.contains(n), !otherNames.contains(n) {
            var variants = [name]
            if name.contains(" ") {
                variants += [name.replacingOccurrences(of: " ", with: ""), name.replacingOccurrences(of: " ", with: "_"),
                             name.replacingOccurrences(of: " ", with: "-")]
            }
            for v in variants {
                out += ["Application Support/\(v)", "Caches/\(v)", "Logs/\(v)", "Saved Application State/\(v).savedState",
                        "Preferences/\(v).plist"].map { lib + "/" + $0 }
            }
            // Top-level dot folders only for multi-word names: "docker" or "local" would hit shared tools.
            if name.contains(" ") {
                for v in [name.lowercased().replacingOccurrences(of: " ", with: "-"),
                          name.lowercased().replacingOccurrences(of: " ", with: "_"),
                          name.lowercased().replacingOccurrences(of: " ", with: "")] {
                    out += [".config/\(v)", ".cache/\(v)", ".local/share/\(v)"].map { home + "/" + $0 }
                }
            }
        }

        // Two copies of one app (Xcode and an Xcode beta) share their files: removing one copy must leave them.
        let idShared = others.contains { $0.bundleID != nil && $0.bundleID?.lowercased() == app.bundleID?.lowercased() }
        if let id = app.bundleID, isBundleID(id), !idShared {
            out += ["Application Support/\(id)", "Caches/\(id)", "Logs/\(id)", "Saved Application State/\(id).savedState",
                    "Containers/\(id)", "WebKit/\(id)", "HTTPStorages/\(id)", "HTTPStorages/\(id).binarycookies",
                    "Cookies/\(id).binarycookies", "Application Scripts/\(id)", "Preferences/\(id).plist",
                    "Caches/com.apple.nsurlsessiond/Downloads/\(id)"].map { lib + "/" + $0 }
            let otherIDs = others.compactMap(\.bundleID)
            // Named after the bundle ID plus more: launch agents (com.foo.app.updater.plist), extension
            // containers, and per-host preferences (com.foo.app.<host UUID>.plist). Plain Preferences take
            // only the exact name: com.google.Chrome.for.testing is another app.
            for dir in ["Preferences/ByHost", "LaunchAgents", "Containers", "Application Scripts"] {
                for entry in (try? FileManager.default.contentsOfDirectory(atPath: lib + "/" + dir)) ?? [] {
                    guard startsWith(entry, id: id), entry.count > id.count,
                          !otherIDs.contains(where: { startsWith(entry, id: $0) && $0.count > id.count }) else { continue }
                    if dir != "Containers" && dir != "Application Scripts" { guard entry.hasSuffix(".plist") else { continue } }
                    out.append(lib + "/" + dir + "/" + entry)
                }
            }
            // com.google.Chrome keeps its data in Application Support/Google/Chrome.
            let parts = id.split(separator: ".").map(String.init)
            if parts.count == 3, parts[2].count >= 3 {
                for root in ["Application Support", "Caches", "Logs"] {
                    guard let vendor = entry(named: parts[1], in: lib + "/" + root),
                          let product = entry(named: parts[2], in: lib + "/" + root + "/" + vendor) else { continue }
                    // Another app of the same vendor and product (not one of this app's own sub-IDs) shares it.
                    let shared = otherIDs.contains { other in
                        let o = other.lowercased().split(separator: ".")
                        return !startsWith(other, id: id) && o.count >= 3 && o[1] == parts[1].lowercased() && o[2] == parts[2].lowercased()
                    }
                    if !shared { out.append(lib + "/" + root + "/" + vendor + "/" + product) }
                }
            }
            // Group Containers: TEAMID.<bundle ID> or group.<bundle ID>, unless another installed app could share it.
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: lib + "/Group Containers")) ?? [] {
                let lower = entry.lowercased(), lid = id.lowercased()
                guard lower == lid || lower.hasSuffix("." + lid) || lower == "group." + lid else { continue }
                let vendor = id.split(separator: ".").prefix(2).joined(separator: ".").lowercased() + "."
                if otherIDs.contains(where: { $0.lowercased().hasPrefix(vendor) }) { continue }
                out.append(lib + "/Group Containers/" + entry)
            }
        }

        var seen = Set<String>()
        // Case-insensitive volume: Caches/Foo and Caches/foo are one place.
        return out.filter { seen.insert($0.lowercased()).inserted && FS.exists($0) }
            .filter { path in !out.contains { $0 != path && path.lowercased().hasPrefix($0.lowercased() + "/") } }
    }

    /// The real spelling of `name` among `dir`'s entries, ignoring case.
    static func entry(named name: String, in dir: String) -> String? {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).first { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: - Running

    /// The running process that uses `path` (its executable is inside it), if any.
    public static func runningProcess(in paths: [String], processes: ProcessTable) -> AgentProcess? {
        let locations = paths.map { Guard.deletionLocation($0) }
        return processes.entries.first { p in
            guard let exe = p.executable else { return false }
            let real = URL(fileURLWithPath: exe).resolvingSymlinksInPath().path
            return locations.contains { real == $0 || real.hasPrefix($0 + "/") || exe.hasPrefix($0 + "/") }
        }
    }

    // MARK: - Uninstalling

    /// Apps whose own folders hold what people would not want to lose with the app: browser
    /// profiles (bookmarks, passwords, extensions), chat history and mail.
    static let personalDataApps = [
        "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.", "org.mozilla.firefox",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "org.chromium.Chromium", "com.kagi.kagimacOS", "app.zen-browser",
        "com.tencent.xinWeChat", "com.tencent.qq", "ru.keepcoder.Telegram", "org.telegram.desktop", "net.whatsapp.WhatsApp",
        "desktop.WhatsApp", "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.bytedance.macos.feishu", "com.electron.lark",
        "com.larksuite.", "org.whispersystems.signal-desktop", "jp.naver.line.mac", "com.microsoft.teams2", "us.zoom.xos",
        "com.alibaba.DingTalkMac", "com.facebook.archon", "com.readdle.smartemail-Mac", "com.microsoft.Outlook",
        "com.mimestream.Mimestream", "it.bloop.airmail2", "com.apple.mail",
    ]

    /// The data folders (not caches or settings) of an app in `personalDataApps`.
    static func isPersonal(_ path: String, bundleID: String?, home: String) -> Bool {
        guard let id = bundleID, personalDataApps.contains(where: { id == $0 || id.hasPrefix($0) }) else { return false }
        return ["/Library/Application Support/", "/Library/Containers/", "/Library/Group Containers/"]
            .contains { path.hasPrefix(home + $0) }
    }

    /// `includePersonal`: also move browser profiles, chat history and mail (left in place by default).
    public static func plan(_ app: InstalledApp, installed: [InstalledApp], home: String = NSHomeDirectory(),
                            processes: ProcessTable? = nil, includePersonal: Bool = false) -> UninstallPlan {
        var app = app
        if app.leftovers.isEmpty { app.leftovers = leftovers(for: app, installed: installed, home: home) }
        if app.bytes == 0 { app.bytes = bundleSize(app.path) }
        app.protected = app.protected ?? protection(app, home: home)
        let kept = includePersonal ? [] : app.leftovers.filter { $0.personal == true }
        let moved = app.leftovers.filter { l in !kept.contains { $0.path == l.path } }
        let paths = [app.path] + moved.map(\.path)
        var plan = UninstallPlan(app: app, paths: paths, bytes: app.bytes + moved.reduce(0) { $0 + $1.bytes },
                                 receipts: receipts(for: app.bundleID))
        plan.kept = kept.isEmpty ? nil : kept
        plan.blocked = refusal(plan, home: home, processes: processes ?? ProcessTable.current(.init(cpu: false)))
        return plan
    }

    static func refusal(_ plan: UninstallPlan, home: String, processes: ProcessTable) -> String? {
        if let why = plan.app.protected { return why }
        if runningProcess(in: [plan.app.path], processes: processes) != nil {
            return tr("%1$@ is running; quit it first", plan.app.name)
        }
        if let p = runningProcess(in: plan.paths, processes: processes) {
            return tr("%1$@ is running; quit it first", ((p.executable ?? p.name) as NSString).lastPathComponent)
        }
        let g = Guard(home: home)
        if let why = g.uninstallRefusal(plan.app.path, bundleIDs: []) { return why }
        return nil
    }

    /// Moves the app and its leftovers to the Trash; nothing is deleted for good. Everything is checked
    /// again right before it moves: protection, running processes, and the guard for each path.
    public static func uninstall(_ plan: UninstallPlan, home: String = NSHomeDirectory(),
                                 processes: (() -> ProcessTable)? = nil) -> CleanResult {
        let table = processes ?? { ProcessTable.current(.init(cpu: false)) }
        let id = "app:" + (plan.app.bundleID ?? plan.app.name)
        var result = CleanResult(id: id, trashed: true)
        if let why = refusal(plan, home: home, processes: table()) {
            result.failed[plan.app.path] = why
        } else {
            let ids = plan.app.bundleID.map { [$0] } ?? []
            let sizes = Dictionary(uniqueKeysWithValues: plan.app.leftovers.map { ($0.path, $0.bytes) })
            trash(plan.paths, bundleIDs: ids, sizes: sizes.merging([plan.app.path: plan.app.bytes]) { a, _ in a },
                  home: home, processes: table, into: &result)
        }
        finish(result, title: plan.app.name, home: home)
        return result
    }

    static func trash(_ paths: [String], bundleIDs: [String], sizes: [String: Int64], home: String,
                      processes: () -> ProcessTable, into result: inout CleanResult,
                      move: (String) throws -> URL = RemovalOperations.live.trash) {
        let g = Guard(home: home)
        let batchID = UUID().uuidString
        let table = processes()
        for path in paths {
            if let why = g.uninstallRefusal(path, bundleIDs: bundleIDs) { result.failed[path] = why; continue }
            guard FS.exists(path) else { continue }
            if runningProcess(in: [path], processes: table) != nil {
                result.failed[path] = tr("a running executable uses this location")
                continue
            }
            do {
                let unrecorded = try TrashBatches.trash(path, bytes: sizes[path] ?? 0, id: batchID, home: home, move: move)
                result.removed.append(path)
                result.bytes += sizes[path] ?? 0
                if let unrecorded { result.failed["batch/" + path] = unrecorded } else { result.trashBatchID = batchID }
            } catch {
                result.failed[path] = (error as NSError).localizedDescription
            }
        }
        TrashBatches.seal(&result, home: home)
    }

    static func finish(_ result: CleanResult, title: String, home: String) {
        if !result.removed.isEmpty {
            ScanReportCache.invalidate(home: home)
            SpaceOverview.invalidate(home: home)
        }
        Cleaner.log(result, item: CleanItem(id: result.id, category: .system, title: title, safety: .review),
                    to: Cleaner.logURL(home: home))
    }

    // MARK: - Orphaned data

    /// Library folders whose entries are named by bundle ID.
    static let orphanRoots = ["Application Support", "Caches", "Logs", "Preferences", "Containers", "WebKit",
                              "HTTPStorages", "Saved Application State", "Application Scripts", "LaunchAgents"]

    /// Caches of build tools, not apps.
    static let toolCaches: Set<String> = ["go-build", "homebrew", "pip", "bun", "yarn", "npm", "node-gyp", "ms-playwright",
                                          "electron-builder", "geoservices", "pnpm", "cef"]

    /// How long data must sit untouched before it counts as left behind.
    public static let orphanAge: TimeInterval = 30 * 86400

    /// Bundle IDs of everything installed or running: every app bundle (and the bundles nested in it)
    /// in the app folders, plus the bundle each running process comes from.
    public static func knownBundleIDs(installed: [InstalledApp], processes: ProcessTable) -> Set<String> {
        var ids = Set(installed.compactMap { $0.bundleID?.lowercased() })
        let fm = FileManager.default
        for app in installed {
            // Helpers and extensions inside the bundle keep their own data folders.
            for sub in ["Contents/Library/LoginItems", "Contents/Library/LaunchServices", "Contents/PlugIns", "Contents/XPCServices", "Contents/Helpers", "Contents/Frameworks"] {
                for entry in (try? fm.contentsOfDirectory(atPath: app.path + "/" + sub)) ?? [] {
                    if let id = read(app.path + "/" + sub + "/" + entry)?.bundleID { ids.insert(id.lowercased()) }
                }
            }
        }
        for p in processes.entries {
            guard let exe = p.executable, let r = exe.range(of: ".app/", options: .backwards) else { continue }
            if let id = read(String(exe[..<r.lowerBound]) + ".app")?.bundleID { ids.insert(id.lowercased()) }
        }
        return ids
    }

    /// A bundle ID left over by an app that is gone: not installed or running, nothing of it touched for
    /// 30 days, and Spotlight knows no app with that ID. `spotlight` returns true when it finds the app
    /// — and also when it fails or times out, since a check that cannot tell must keep the data.
    public static func orphans(home: String = NSHomeDirectory(), known: Set<String>, now: Date = Date(),
                               spotlight: (String) -> Bool = spotlightFinds, minimumBytes: Int64 = 0,
                               cancellation: ScanCancellation? = nil) -> [OrphanData] {
        let lib = home + "/Library"
        var byID: [String: [String]] = [:]
        for root in orphanRoots {
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: lib + "/" + root)) ?? [] {
                guard let id = orphanID(entry, root: root) else { continue }
                byID[id, default: []].append(lib + "/" + root + "/" + entry)
            }
        }
        var out: [OrphanData] = []
        for (id, paths) in byID.sorted(by: { $0.key < $1.key }) {
            if cancellation?.isCancelled == true { break }
            let lower = id.lowercased()
            if known.contains(where: { lower == $0 || startsWith(lower, id: $0) || startsWith($0, id: lower) }) { continue }
            let items = paths.map { path -> AppLeftover in
                let size = FS.size(path, trackNewest: true, cancellation: cancellation)
                return AppLeftover(path: path, bytes: size.bytes, lastUsed: newest(path, size.newest))
            }
            let data = OrphanData(bundleID: id, items: items)
            guard data.bytes >= minimumBytes else { continue }
            if let last = data.lastUsed, now.timeIntervalSince(last) < orphanAge { continue }
            if spotlight(id) { continue }
            out.append(data)
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    /// The bundle ID an entry under a Library root is named after, or nil when it is not app data.
    static func orphanID(_ entry: String, root: String) -> String? {
        var base = entry
        for suffix in [".plist", ".savedState", ".binarycookies"] where base.hasSuffix(suffix) { base = String(base.dropLast(suffix.count)) }
        guard !base.hasPrefix("."), isBundleID(base), !isProtected(base), !toolCaches.contains(base.lowercased()) else { return nil }
        if (root == "Preferences" || root == "LaunchAgents") && !entry.hasSuffix(".plist") { return nil }
        return base
    }

    /// Newest of the item's own modification and change times and what is inside it.
    static func newest(_ path: String, _ inside: Date?) -> Date? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return inside }
        let own = max(st.st_mtimespec.tv_sec, st.st_ctimespec.tv_sec)
        let d = Date(timeIntervalSince1970: TimeInterval(own))
        return max(d, inside ?? d)
    }

    /// True when Spotlight finds an app with this bundle ID, or cannot answer within 5 seconds.
    public static func spotlightFinds(_ bundleID: String) -> Bool {
        guard isBundleID(bundleID) else { return true }
        let (status, output) = Shell.exec(["mdfind", "kMDItemCFBundleIdentifier == '\(bundleID)'"], timeout: 5)
        return status != 0 || !output.isEmpty
    }

    /// Moves orphaned data to the Trash after checking again that it is still orphaned.
    public static func removeOrphans(_ picked: [OrphanData], home: String = NSHomeDirectory(), installed: [InstalledApp]? = nil,
                                     processes: (() -> ProcessTable)? = nil,
                                     spotlight: (String) -> Bool = spotlightFinds) -> [CleanResult] {
        let table = processes ?? { ProcessTable.current(.init(cpu: false)) }
        let apps = installed ?? AppUninstaller.installed(home: home)
        let known = knownBundleIDs(installed: apps, processes: table())
        let wanted = Set(picked.map(\.bundleID))
        let current = orphans(home: home, known: known, spotlight: { wanted.contains($0) ? spotlight($0) : true })
        return picked.map { data in
            var result = CleanResult(id: "leftovers:" + data.bundleID, trashed: true)
            let still = current.first { $0.bundleID == data.bundleID }
            if let still {
                let current = Set(still.items.map(\.path))
                let paths = data.items.map(\.path).filter(current.contains)
                let sizes = Dictionary(uniqueKeysWithValues: still.items.map { ($0.path, $0.bytes) })
                trash(paths, bundleIDs: [data.bundleID], sizes: sizes, home: home, processes: table, into: &result)
            } else {
                result.failed[data.bundleID] = tr("no longer looks left behind: an app uses it again, or it changed")
            }
            finish(result, title: data.bundleID, home: home)
            return result
        }
    }
}

// MARK: - Guard

extension Guard {
    /// The guard plus what uninstalling needs: an app bundle directly in /Applications or
    /// ~/Applications, and a preferences file named after one of `bundleIDs`. Everything else is
    /// refused exactly as `refusal` refuses it.
    public func uninstallRefusal(_ path: String, bundleIDs: [String]) -> String? {
        if !path.hasPrefix("/") || path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) { return "relative path" }
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        let location = Guard.deletionLocation(p)
        let parent = (location as NSString).deletingLastPathComponent
        let name = (location as NSString).lastPathComponent
        let canonicalHome = URL(fileURLWithPath: home).resolvingSymlinksInPath().path

        if name.hasSuffix(".app"), name.count > 4 {
            if location.hasPrefix("/System/") { return "part of macOS" }
            let appDirs = ["/Applications", canonicalHome + "/Applications"]
            if appDirs.contains(parent) { return nil }
            // One folder down, as suites install: never inside another bundle.
            let grand = (parent as NSString).deletingLastPathComponent
            if appDirs.contains(grand), !parent.hasSuffix(".app") { return nil }
        }
        let prefDirs = [canonicalHome + "/Library/Preferences", canonicalHome + "/Library/Preferences/ByHost"]
        if prefDirs.contains(parent), name.hasSuffix(".plist") {
            var st = stat()
            let isFile = lstat(location, &st) != 0 || (st.st_mode & S_IFMT) == S_IFREG
            if isFile, bundleIDs.contains(where: { AppUninstaller.isBundleID($0) && AppUninstaller.startsWith(name, id: $0) }) { return nil }
        }
        return refusal(path)
    }
}
