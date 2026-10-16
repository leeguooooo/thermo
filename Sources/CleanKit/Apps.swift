import AgentCore
import Foundation
import Darwin
import ThermoL10n

/// An app bundle found in /Applications or ~/Applications.
public struct InstalledApp: Codable, Identifiable, Sendable, Equatable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var bundleID: String?
    public var version: String?
    /// What the inventory actually observed, before later measuring and review.
    public var inventoryIdentity: AppReviewIdentity? = nil
    /// Size of the bundle itself (0 until measured).
    public var bytes: Int64 = 0
    public var sizeState: AppSizeState? = nil
    public var relatedDataState: AppSizeState? = nil
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
    public var sizeState: AppSizeState? = nil
    /// Newest modification inside it.
    public var lastUsed: Date?
    /// A browser profile, chat history or mailbox: kept unless asked for.
    public var personal: Bool?

    public init(path: String, bytes: Int64, lastUsed: Date? = nil, personal: Bool? = nil, sizeState: AppSizeState? = nil) {
        self.path = path; self.bytes = bytes; self.lastUsed = lastUsed; self.personal = personal; self.sizeState = sizeState
    }
}

/// Data an app left behind after it was deleted, grouped by its bundle ID.
public struct OrphanData: Codable, Identifiable, Sendable, Equatable {
    public var id: String { bundleID }
    public var bundleID: String
    public var items: [AppLeftover]
    public var blocked: String? = nil
    public var dataIdentities: [String: String]? = nil
    public var ownership: AppOwnershipSnapshot? = nil

    public init(bundleID: String, items: [AppLeftover]) { self.bundleID = bundleID; self.items = items }
    public var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    public var lastUsed: Date? { items.compactMap(\.lastUsed).max() }
}

public enum OrphanAppPresence: String, Sendable { case present, absent, unavailable }

public struct OrphanScanIssue: Codable, Sendable, Hashable {
    public var message: String
    public var path: String?
    public init(_ message: String, path: String? = nil) { self.message = message; self.path = path }
}

public struct OrphanScanReport: Codable, Sendable {
    public let items: [OrphanData]
    public let issues: [OrphanScanIssue]
    public let cancelled: Bool
    public let complete: Bool
    public init(items: [OrphanData] = [], issues: [OrphanScanIssue] = [], cancelled: Bool = false) {
        self.items = items; self.issues = issues; self.cancelled = cancelled
        complete = issues.isEmpty && !cancelled
    }
}

/// What an uninstall will do, shown in full before anything moves.
public struct UninstallPlan: Codable, Sendable {
    public var app: InstalledApp
    /// Selected Trash paths: the optional bundle first, followed by associated data.
    public var paths: [String]
    public var bytes: Int64
    public var sizeState: AppSizeState? = nil
    /// Captured before review; absent in older serialized plans, which must be reviewed again.
    public var identities: [String: String]? = nil
    public var appIdentity: AppReviewIdentity? = nil
    /// Set when it cannot be uninstalled now.
    public var blocked: String?
    /// Installer packages that put files outside the home folder; Thermo leaves those.
    public var receipts: [String] = []
    /// Personal data left in place (profiles, chat history, mail), unless the plan includes it.
    public var kept: [AppLeftover]?
    /// Leftovers left in place because the user's whitelist keeps them.
    public var whitelisted: [String]? = nil
    /// Absent in older plans means a normal uninstall; false explicitly preserves the bundle.
    public var removeApp: Bool? = nil
    public var removesApp: Bool { removeApp ?? true }
    public var ownership: AppOwnershipSnapshot? = nil
    public var dataIdentities: [String: String]? = nil
    public var ownershipKept: [String]? = nil
}

public enum AppUninstaller {
    // MARK: - Finding apps

    public static func appDirs(home: String = NSHomeDirectory()) -> [String] {
        ["/Applications", "/Applications/Utilities", home + "/Applications"]
    }

    /// Apps in /Applications and ~/Applications, read from their Info.plist, sorted by name. Sizes are not measured.
    public static func installed(home: String = NSHomeDirectory(), dirs: [String]? = nil, cancellation: ScanCancellation? = nil) -> [InstalledApp] {
        installedReport(home: home, dirs: dirs, cancellation: cancellation).apps
    }

    public static func read(_ path: String) -> InstalledApp? {
        let identity = AppReviewIdentity.capture(path)
        func observed(_ app: InstalledApp) -> InstalledApp? {
            var app = app
            if identity != nil, AppReviewIdentity.capture(path) == identity { app.inventoryIdentity = identity }
            return app
        }
        let plist = path + "/Contents/Info.plist"
        guard let data = FileManager.default.contents(atPath: plist),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            // A bundle without a readable Info.plist is still an app the user can see and remove.
            guard FS.exists(path) else { return nil }
            return observed(InstalledApp(path: path, name: ((path as NSString).lastPathComponent as NSString).deletingPathExtension, bundleID: nil))
        }
        let file = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let id = (info["CFBundleIdentifier"] as? String).flatMap { AppOwnershipSnapshot.validDeclaredID($0) ? $0 : nil }
        return observed(InstalledApp(path: path, name: file, bundleID: id,
                            version: (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String)))
    }

    /// Publishes bundle allocation first, then associated data. Default discovery is bounded;
    /// budget:nil requests a full measurement. Callbacks may publish twice per app, from workers.
    public static func measure(_ apps: [InstalledApp], home: String = NSHomeDirectory(), cancellation: ScanCancellation? = nil,
                               budget: TimeInterval? = 60,
                               each: ((InstalledApp) -> Void)? = nil) -> [InstalledApp] {
        let sizing: (String, ScanCancellation?) -> TreeSize = budget == nil ? FS.allocatedSize : { path, _ in FS.discoverySize(path, maxEntries: 20_000) }
        return measureInventory(apps, home: home, cancellation: cancellation, budget: budget, size: sizing, each: each)
    }

    private static let measurementQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = min(4, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
        queue.qualityOfService = .utility
        return queue
    }()

    static func measureInventory(_ apps: [InstalledApp], home: String, cancellation: ScanCancellation?, budget: TimeInterval?,
                                 size: @escaping (String, ScanCancellation?) -> TreeSize,
                                 each: ((InstalledApp) -> Void)?) -> [InstalledApp] {
        let cancellation = cancellation ?? ScanCancellation.current ?? ScanCancellation()
        if cancellation.isCancelled { return apps }
        var out = apps.map { app -> InstalledApp in
            var app = app; app.bytes = 0; app.sizeState = .unmeasured; app.leftovers = []; app.relatedDataState = .unmeasured
            return app
        }
        let lock = NSLock()
        let group = DispatchGroup()
        func publish(_ app: InstalledApp, at i: Int) {
            lock.lock()
            guard !cancellation.isCancelled else { lock.unlock(); return }
            out[i] = app
            lock.unlock()
            if !cancellation.isCancelled { each?(app) }
        }
        var bundles: [Operation] = [], related: [Operation] = []
        let barrier = BlockOperation()
        for i in apps.indices {
            group.enter()
            let bundle = BlockOperation {
                defer { group.leave() }
                ScanCancellation.withCurrent(cancellation) {
                    if cancellation.isCancelled { return }
                    var app = apps[i]
                    app.relatedDataState = .unmeasured; app.leftovers = []
                    let size = size(app.path, cancellation)
                    let exists = FS.isDirectory(app.path)
                    app.bytes = exists ? max(size.bytes, size.allocated) : 0
                    app.sizeState = AppSize.measured(size, exists: exists)
                    publish(app, at: i)
                }
            }
            bundles.append(bundle); barrier.addDependency(bundle)
            group.enter()
            let files = BlockOperation {
                defer { group.leave() }
                ScanCancellation.withCurrent(cancellation) {
                    guard !cancellation.isCancelled else { return }
                    lock.lock(); var app = out[i]; lock.unlock()
                    let related = checkedLeftovers(for: app, installed: apps, home: home)
                    app.leftovers = related.items
                    app.relatedDataState = related.state
                    publish(app, at: i)
                }
            }
            files.addDependency(barrier); related.append(files)
        }
        measurementQueue.addOperations(bundles + [barrier] + related, waitUntilFinished: false)
        let began = DispatchTime.now().uptimeNanoseconds
        let seconds = budget.map { $0.isFinite ? max(0, $0) : 0 }
        while group.wait(timeout: .now() + 0.05) != .success {
            if cancellation.isCancelled { break }
            if let seconds, Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9 >= seconds { cancellation.cancel(); break }
        }
        lock.lock(); defer { lock.unlock() }
        return out
    }

    /// The bundle's size as Finder shows it. Browsers keep their versions as clones, so the private
    /// bytes alone (what disk cleanup reports) can be a few megabytes for a gigabyte app.
    public static func bundleSize(_ path: String, cancellation: ScanCancellation? = nil) -> Int64 {
        let size = FS.allocatedSize(path, cancellation: cancellation)
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
    public static func cask(for app: InstalledApp, caskrooms: [String] = caskrooms, cancellation: ScanCancellation? = nil) -> String? {
        let fm = FileManager.default
        let file = (app.path as NSString).lastPathComponent
        for room in caskrooms {
            for token in (try? fm.contentsOfDirectory(atPath: room)) ?? [] where !token.hasPrefix(".") {
                if cancellation?.isCancelled == true { return nil }
                let meta = room + "/" + token + "/.metadata"
                guard let walker = fm.enumerator(atPath: meta) else { continue }
                for case let rel as String in walker {
                    if cancellation?.isCancelled == true { return nil }
                    guard rel.hasSuffix(".json") || rel.hasSuffix(".rb") else { continue }
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
        checkedLeftovers(for: app, installed: installed, home: home).items
    }

    static func checkedLeftovers(for app: InstalledApp, installed: [InstalledApp], home: String) -> (items: [AppLeftover], state: AppSizeState) {
        var incomplete = false
        let paths = candidates(for: app, installed: installed, home: home, discoveryFailed: { incomplete = true })
        let items = paths.compactMap { path -> AppLeftover? in
            var st = stat()
            guard lstat(path, &st) == 0 else { incomplete = true; return nil }
            let size = FS.size(path, trackNewest: true)
            return AppLeftover(path: path, bytes: size.bytes, lastUsed: size.newest,
                               personal: isPersonal(path, bundleID: app.bundleID, home: home) ? true : nil,
                               sizeState: AppSize.measured(size, exists: FS.exists(path)))
        }
        let bytes = items.reduce(Int64(0)) { $0 + $1.bytes }
        return (items, AppSize.combined(items.map(\.effectiveSizeState) + [incomplete ? .unavailable : .complete], bytes: bytes))
    }

    static func candidates(for app: InstalledApp, installed: [InstalledApp], home: String, discoveryFailed: (() -> Void)? = nil) -> [String] {
        let lib = home + "/Library"
        var out: [String] = []
        let others = installed.filter { $0.path != app.path }
        let otherNames = Set(others.map { normalized($0.name) })
        let idShared = others.contains { $0.bundleID != nil && $0.bundleID?.lowercased() == app.bundleID?.lowercased() }

        // Names: "Maestro Studio" → MaestroStudio, Maestro_Studio, Maestro-Studio, and lowercase forms.
        let name = app.name
        let n = normalized(name)
        if name.count >= 3, !sharedNames.contains(n), !otherNames.contains(n), !idShared {
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
                for entry in names(in: lib + "/" + dir, onFailure: discoveryFailed) ?? [] {
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
                    guard let vendor = entry(named: parts[1], in: lib + "/" + root, onFailure: discoveryFailed),
                          let product = entry(named: parts[2], in: lib + "/" + root + "/" + vendor, onFailure: discoveryFailed) else { continue }
                    // Another app of the same vendor and product (not one of this app's own sub-IDs) shares it.
                    let shared = otherIDs.contains { other in
                        let o = other.lowercased().split(separator: ".")
                        return !startsWith(other, id: id) && o.count >= 3 && o[1] == parts[1].lowercased() && o[2] == parts[2].lowercased()
                    }
                    if !shared { out.append(lib + "/" + root + "/" + vendor + "/" + product) }
                }
            }
            // Group Containers: TEAMID.<bundle ID> or group.<bundle ID>, unless another installed app could share it.
            for entry in names(in: lib + "/Group Containers", onFailure: discoveryFailed) ?? [] {
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
    static func entry(named name: String, in dir: String, onFailure: (() -> Void)? = nil) -> String? {
        (names(in: dir, onFailure: onFailure) ?? []).first { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// A name-only pass must not request URL attributes for every cache/container entry.
    /// In particular, a file provider's slow attribute lookup must not block unrelated apps.
    static func names(in path: String, onFailure: (() -> Void)? = nil) -> [String]? {
        guard let directory = opendir(path) else { if errno != ENOENT { onFailure?() }; return nil }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            if ScanCancellation.current?.isCancelled == true { onFailure?(); return nil }
            errno = 0
            guard let entry = readdir(directory) else { if errno != 0 { onFailure?(); return nil }; return names }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
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
                            processes: ProcessTable? = nil, includePersonal: Bool = false, removeApp: Bool = true,
                            cancellation: ScanCancellation? = nil) -> UninstallPlan {
        plan(app, installed: installed, home: home, processes: processes, includePersonal: includePersonal,
             removeApp: removeApp, cancellation: cancellation, ownershipDirectories: appDirs(home: home))
    }

    static func plan(_ app: InstalledApp, installed: [InstalledApp], home: String, processes: ProcessTable? = nil,
                     includePersonal: Bool = false, removeApp: Bool = true, cancellation: ScanCancellation? = nil,
                     ownershipDirectories: [String]) -> UninstallPlan {
        let token = cancellation ?? ScanCancellation.current
        var plan = ScanCancellation.withCurrent(token) {
            let observed = processes ?? ProcessTable.current(.init(cpu: false))
            let runtime = AppOwnershipSnapshot.supplementalPaths(observed, directories: ownershipDirectories)
            let extras = installed.map(\.path).filter { !AppOwnershipSnapshot.isDiscovered($0, directories: ownershipDirectories) }
            let ownership = AppOwnershipSnapshot.capture(directories: ownershipDirectories, additionalPaths: extras + runtime, requiredPaths: runtime)
            var result = makePlan(app, installed: ownership.dataOwners(excludingEmbeddedIn: app.path), home: home, processes: processes, includePersonal: includePersonal,
                                  removeApp: removeApp, ownership: ownership)
            if !observed.available { result.blocked = tr("Could not verify running apps; refresh before removing files") }
            return result
        }
        if token?.isCancelled == true {
            plan.blocked = tr("Review stopped; review again before removing files")
            plan.appIdentity = nil
        }
        return plan
    }

    private static func makePlan(_ app: InstalledApp, installed: [InstalledApp], home: String,
                                 processes: ProcessTable?, includePersonal: Bool, removeApp: Bool, ownership: AppOwnershipSnapshot) -> UninstallPlan {
        var app = app
        let previousPaths = app.leftovers.map(\.path)
        let related = checkedLeftovers(for: app, installed: installed, home: home)
        let possible = candidates(for: app, installed: [app], home: home)
        let keptByOwnership = Set(possible + previousPaths).subtracting(related.items.map(\.path)).filter { FS.exists($0) }.sorted()
        app.leftovers = related.items; app.relatedDataState = related.state
        if removeApp && (app.sizeState == nil || app.bundleSizeState != .complete) {
            let size = FS.allocatedSize(app.path)
            let exists = FS.isDirectory(app.path)
            app.bytes = exists ? max(size.bytes, size.allocated) : 0
            app.sizeState = AppSize.measured(size, exists: exists)
        }
        app.protected = app.protected ?? protection(app, home: home)
        let kept = includePersonal ? [] : app.leftovers.filter { $0.personal == true }
        let whitelist = try? Whitelist.loadForRemoval(home: home)
        let saved = app.leftovers.map(\.path).filter { whitelist?.protects($0) == true }
        let moved = app.leftovers.filter { l in !kept.contains { $0.path == l.path } && !saved.contains(l.path) }
        let paths = (removeApp ? [app.path] : []) + moved.map(\.path)
        var plan = UninstallPlan(app: app, paths: paths, bytes: (removeApp ? app.bytes : 0) + moved.reduce(0) { $0 + $1.bytes },
                                 receipts: receipts(for: app.bundleID))
        plan.kept = kept.isEmpty ? nil : kept
        plan.removeApp = removeApp
        plan.ownership = ownership
        plan.ownershipKept = keptByOwnership.isEmpty ? nil : keptByOwnership
        plan.dataIdentities = moved.reduce(into: [:]) { $0[$1.path] = AppDataReviewIdentity.of($1.path) }
        plan.sizeState = AppSize.combined((removeApp ? [app.bundleSizeState] : []) + [app.relatedDataState ?? .unmeasured] + moved.map(\.effectiveSizeState), bytes: plan.bytes)
        plan.whitelisted = saved.isEmpty ? nil : saved
        plan.identities = paths.reduce(into: [:]) { result, path in result[path] = FileIdentity.of(path) }
        plan.appIdentity = AppReviewIdentity.capture(app.path)
        plan.blocked = refusal(plan, home: home, processes: processes ?? ProcessTable.current(.init(cpu: false)))
        let current = read(app.path)
        if current?.inventoryIdentity == nil {
            plan.appIdentity = nil
            plan.blocked = plan.blocked ?? tr("Could not verify this app's file identity; inspect it in Finder")
        } else if current?.bundleID != app.bundleID || current?.version != app.version ||
            (app.inventoryIdentity != nil && current?.inventoryIdentity != app.inventoryIdentity) {
            plan.appIdentity = nil
            plan.blocked = plan.blocked ?? tr("The app changed since the inventory; refresh the app list and review again")
        } else {
            plan.appIdentity = current?.inventoryIdentity
        }
        if !ownership.complete, !moved.isEmpty {
            plan.blocked = plan.blocked ?? tr("Could not verify installed app ownership; refresh before removing associated data")
        }
        return plan
    }

    static func refusal(_ plan: UninstallPlan, home: String, processes: ProcessTable) -> String? {
        if !processes.available { return tr("Could not verify running apps; refresh before removing files") }
        let appLocation = Guard.deletionLocation(plan.app.path)
        if plan.removesApp != plan.paths.contains(plan.app.path) || (!plan.removesApp && plan.paths.contains(where: {
            let location = Guard.deletionLocation($0)
            return location == appLocation || location.hasPrefix(appLocation + "/") || appLocation.hasPrefix(location + "/")
        })) { return tr("The removal selection changed; review it again") }
        if !plan.removesApp && plan.paths.isEmpty { return tr("No associated files are selected; the app will be kept") }
        if let why = plan.app.protected { return why }
        do {
            let whitelist = try Whitelist.loadForRemoval(home: home)
            if plan.removesApp && whitelist.protects(plan.app.path) { return tr(Whitelist.reason) }
        } catch { return Whitelist.unreadable(error) }
        if runningProcess(in: [plan.app.path], processes: processes) != nil {
            return tr("%1$@ is running; quit it first", plan.app.name)
        }
        if let p = runningProcess(in: plan.paths, processes: processes) {
            return tr("%1$@ is running; quit it first", ((p.executable ?? p.name) as NSString).lastPathComponent)
        }
        let g = Guard(home: home)
        if let why = g.uninstallRefusal(plan.app.path, bundleIDs: []) { return why }
        // macOS will not move a folder the user cannot write to (its ".." entry has to change), so an
        // app installed as root would fail halfway; say so before anything moves.
        if plan.removesApp && access(plan.app.path, W_OK) != 0 {
            return tr("%1$@ belongs to the administrator account, so Thermo cannot move it. Drag it to the Trash in Finder, which asks for your password.", plan.app.name)
        }
        return nil
    }

    /// Moves selected app/data paths to the Trash; a data-only plan keeps the bundle. Everything is checked
    /// again right before it moves: protection, running processes, and the guard for each path.
    public static func uninstall(_ plan: UninstallPlan, home: String = NSHomeDirectory(),
                                 processes: (() -> ProcessTable)? = nil) -> CleanResult {
        uninstall(plan, home: home, processes: processes, move: RemovalOperations.live.trash)
    }

    static func uninstall(_ plan: UninstallPlan, home: String, processes: (() -> ProcessTable)?, ownershipDirectories: [String]? = nil,
                          move: (String) throws -> URL) -> CleanResult {
        let table = processes ?? { ProcessTable.current(.init(cpu: false)) }
        let current = table()
        let directories = ownershipDirectories ?? appDirs(home: home)
        let runtime = AppOwnershipSnapshot.supplementalPaths(current, directories: directories)
        let id = (plan.removesApp ? "app:" : "app-data:") + (plan.app.bundleID ?? plan.app.name)
        var result = CleanResult(id: id, trashed: true)
        if let why = plan.blocked ?? refusal(plan, home: home, processes: current) {
            result.failed[plan.app.path] = why
        } else if plan.appIdentity == nil || AppReviewIdentity.capture(plan.app.path) != plan.appIdentity {
            result.failed[plan.app.path] = plan.removesApp ? tr("The app changed after review; review the uninstall again") : tr("The app changed after review; review the data removal again")
        } else if plan.paths.contains(where: { $0 != plan.app.path }) &&
                    (plan.ownership?.complete != true || plan.ownership != AppOwnershipSnapshot.capture(directories: directories, additionalPaths: (plan.ownership?.extraPaths ?? []) + runtime, requiredPaths: runtime)) {
            result.failed[plan.app.path] = tr("Installed apps changed or ownership could not be verified; review associated data again")
        } else if let changed = plan.paths.first(where: { $0 != plan.app.path &&
            (plan.dataIdentities?[$0] == nil || plan.dataIdentities?[$0] != AppDataReviewIdentity.of($0)) }) {
            result.failed[changed] = tr("Associated data changed after review; review it again")
        } else {
            let ids = plan.app.bundleID.map { [$0] } ?? []
            let sizes = Dictionary(uniqueKeysWithValues: plan.app.leftovers.map { ($0.path, $0.bytes) })
            trash(plan.paths, bundleIDs: ids, sizes: sizes.merging([plan.app.path: plan.app.bytes]) { a, _ in a },
                  home: home, processes: table, into: &result, identities: plan.identities ?? [:],
                  incompletePaths: Set(plan.app.leftovers.filter { $0.effectiveSizeState != .complete }.map(\.path))
                    .union(plan.app.bundleSizeState == .complete ? [] : [plan.app.path]),
                  reviewIdentities: plan.dataIdentities ?? [:], bundlePath: plan.app.path,
                  ownership: plan.paths.contains(where: { $0 != plan.app.path }) ? plan.ownership : nil, move: move)
        }
        finish(result, title: plan.app.name, home: home)
        return result
    }

    static func trash(_ paths: [String], bundleIDs: [String], sizes: [String: Int64], home: String,
                      processes: () -> ProcessTable, into result: inout CleanResult,
                      identities: [String: String]? = nil,
                      incompletePaths: Set<String> = [],
                      reviewIdentities: [String: String]? = nil,
                      bundlePath: String? = nil,
                      ownership: AppOwnershipSnapshot? = nil,
                      recheckOwnershipEachPath: Bool = false,
                      move: (String) throws -> URL = RemovalOperations.live.trash) {
        let g = Guard(home: home)
        let batchID = UUID().uuidString
        do { _ = try Whitelist.loadForRemoval(home: home) } catch {
            for path in paths { result.failed[path] = Whitelist.unreadable(error) }
            return
        }
        for (index, path) in paths.enumerated() {
            let table = processes()
            if !table.available {
                for remaining in paths[index...] { result.failed[remaining] = tr("Could not verify running apps; refresh before removing files") }
                break
            }
            if let ownership, !Set(AppOwnershipSnapshot.supplementalPaths(table, directories: ownership.roots)).isSubset(of: Set(ownership.extraPaths)) {
                for remaining in paths[index...] { result.failed[remaining] = tr("Running app ownership changed; review associated data again") }
                break
            }
            if recheckOwnershipEachPath, let ownership,
               ownership != AppOwnershipSnapshot.capture(directories: ownership.roots, additionalPaths: ownership.extraPaths,
                                                          requiredPaths: ownership.extraPaths) {
                for remaining in paths[index...] { result.failed[remaining] = tr("Installed apps changed or ownership could not be verified; review associated data again") }
                break
            }
            if let bundlePath, runningProcess(in: [bundlePath], processes: table) != nil {
                for remaining in paths[index...] { result.failed[remaining] = tr("a running executable uses this location") }
                break
            }
            do {
                if try Whitelist.loadForRemoval(home: home).protects(path) {
                    result.whitelisted = (result.whitelisted ?? []) + [path]; continue
                }
            } catch {
                for remaining in paths[index...] { result.failed[remaining] = Whitelist.unreadable(error) }
                break
            }
            if let why = g.uninstallRefusal(path, bundleIDs: bundleIDs) { result.failed[path] = why; continue }
            guard FS.exists(path) else { continue }
            if let identities, identities[path] == nil || identities[path] != FileIdentity.of(path) {
                result.failed[path] = tr("The item changed after review; review the uninstall again")
                continue
            }
            if runningProcess(in: [path], processes: table) != nil {
                result.failed[path] = tr("a running executable uses this location")
                continue
            }
            if let reviewIdentities, path != bundlePath, reviewIdentities[path] == nil || reviewIdentities[path] != AppDataReviewIdentity.of(path) {
                result.failed[path] = tr("Associated data changed after review; review it again")
                continue
            }
            do {
                let unrecorded = try TrashBatches.trash(path, bytes: sizes[path] ?? 0, id: batchID, home: home, move: move)
                result.removed.append(path)
                if incompletePaths.contains(path) { result.bytesIncomplete = true }
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
        Cleaner.log(result, item: CleanItem(id: result.id, category: .system, title: title, safety: .review), home: home)
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

    /// Declared IDs of supplied apps, standard embedded bundle locations, and observed running apps.
    /// This compatibility set omits quality details; orphanReport preserves inventory failures.
    public static func knownBundleIDs(installed: [InstalledApp], processes: ProcessTable) -> Set<String> {
        let paths = installed.map(\.path) + AppOwnershipSnapshot.supplementalPaths(processes, directories: [])
        let ownership = AppOwnershipSnapshot.capture(directories: [], additionalPaths: paths)
        return Set(installed.compactMap { $0.bundleID?.lowercased() }).union(ownership.declaredBundleIDs)
    }

    /// A bundle ID left over by an app that is gone: not installed or running, nothing of it touched for
    /// 30 days, and Spotlight knows no app with that ID. `spotlight` returns true when it finds the app
    /// — and also when it fails or times out, since a check that cannot tell must keep the data.
    public static func orphans(home: String = NSHomeDirectory(), known: Set<String>, now: Date = Date(),
                               spotlight: (String) -> Bool = spotlightFinds, minimumBytes: Int64 = 0,
                               cancellation: ScanCancellation? = nil) -> [OrphanData] {
        reviewedOrphans(home: home, known: known, now: now, spotlight: spotlight, minimumBytes: minimumBytes,
                        cancellation: cancellation, processes: ProcessTable.current(.init(cpu: false)), directories: appDirs(home: home))
    }

    static func reviewedOrphans(home: String, known: Set<String>, now: Date, spotlight: (String) -> Bool,
                                minimumBytes: Int64 = 0, cancellation: ScanCancellation? = nil,
                                processes: ProcessTable, directories: [String]) -> [OrphanData] {
        reviewedOrphanReport(home: home, known: known, now: now, spotlight: { spotlight($0) ? .present : .absent },
                             minimumBytes: minimumBytes, cancellation: cancellation, processes: processes, directories: directories).items
    }

    public static func orphanReport(home: String = NSHomeDirectory(), known: Set<String> = [], now: Date = Date(),
                                    spotlight: ((String) -> OrphanAppPresence)? = nil, minimumBytes: Int64 = 0,
                                    cancellation: ScanCancellation? = nil) -> OrphanScanReport {
        reviewedOrphanReport(home: home, known: known, now: now, spotlight: spotlight ?? spotlightPresence,
                             minimumBytes: minimumBytes, cancellation: cancellation,
                             processes: ProcessTable.current(.init(cpu: false)), directories: appDirs(home: home))
    }

    static func reviewedOrphanReport(home: String, known: Set<String>, now: Date, spotlight: (String) -> OrphanAppPresence,
                                     minimumBytes: Int64 = 0, cancellation: ScanCancellation? = nil,
                                     processes: ProcessTable, directories: [String]) -> OrphanScanReport {
        let previousCancellation = ScanCancellation.current
        ScanCancellation.current = cancellation ?? previousCancellation
        defer { ScanCancellation.current = previousCancellation }
        guard ScanCancellation.current?.isCancelled != true else { return .init(cancelled: true) }
        let runtime = AppOwnershipSnapshot.supplementalPaths(processes, directories: directories)
        var ownership = AppOwnershipSnapshot.capture(directories: directories, additionalPaths: runtime, requiredPaths: runtime)
        if !processes.available { ownership.issues.append("Could not verify running apps; refresh before removing files") }
        var issues = ownership.issues.map { issue in
            issue.hasPrefix("/") ? OrphanScanIssue("Could not verify installed app ownership", path: issue) : OrphanScanIssue(issue)
        }
        let known = known.union(ownership.declaredBundleIDs)
        let lib = home + "/Library"
        var byID: [String: [String]] = [:]
        for root in orphanRoots {
            if ScanCancellation.current?.isCancelled == true { break }
            let directory = lib + "/" + root
            let entries = names(in: directory, onFailure: { issues.append(.init("Could not read residual data directory", path: directory)) }) ?? []
            for entry in entries {
                guard let id = orphanID(entry, root: root) else { continue }
                byID[id, default: []].append(lib + "/" + root + "/" + entry)
            }
        }
        var out: [OrphanData] = []
        let whitelist: Whitelist?, whitelistIssue: String?
        do { whitelist = try Whitelist.loadForRemoval(home: home); whitelistIssue = nil }
        catch {
            whitelist = nil; whitelistIssue = Whitelist.unreadable(error)
            issues.append(.init(Whitelist.unreadable(error), path: Whitelist.url(home: home).path))
        }
        for (id, all) in byID.sorted(by: { $0.key < $1.key }) {
            if ScanCancellation.current?.isCancelled == true { break }
            let paths = all.filter { whitelist?.protects($0) != true }
            if paths.isEmpty { continue }
            let lower = id.lowercased()
            if known.contains(where: { lower == $0 || startsWith(lower, id: $0) || startsWith($0, id: lower) }) { continue }
            var identities: [String: String] = [:]
            var changed = false
            let items = paths.map { path -> AppLeftover in
                let before = AppDataReviewIdentity.of(path)
                let size = FS.size(path, trackNewest: true, cancellation: cancellation)
                if let before, before == AppDataReviewIdentity.of(path) { identities[path] = before } else { changed = true }
                return AppLeftover(path: path, bytes: size.bytes, lastUsed: newest(path, size.newest), sizeState: AppSize.measured(size, exists: FS.exists(path)))
            }
            var data = OrphanData(bundleID: id, items: items)
            data.dataIdentities = identities
            data.ownership = ownership
            for item in items where item.effectiveSizeState != .complete {
                issues.append(.init("Residual data measurement was incomplete", path: item.path))
            }
            if changed { issues.append(.init("Associated data changed after review; review it again", path: paths.first)) }
            guard data.bytes >= minimumBytes || data.sizeState != .complete else { continue }
            if let last = data.lastUsed, now.timeIntervalSince(last) < orphanAge { continue }
            switch spotlight(id) {
            case .present: continue
            case .unavailable:
                issues.append(.init("Spotlight could not verify whether the app is installed", path: paths.first))
                continue
            case .absent: break
            }
            if data.sizeState != .complete { data.blocked = tr("This data could not be fully checked; inspect it in Finder before removing it") }
            if changed { data.blocked = tr("Associated data changed after review; review it again") }
            if !ownership.complete { data.blocked = tr("Could not verify installed app ownership; refresh before removing associated data") }
            if let whitelistIssue { data.blocked = whitelistIssue }
            out.append(data)
        }
        return .init(items: out.sorted { $0.bytes > $1.bytes }, issues: Array(Set(issues)).sorted {
            ($0.path ?? "", $0.message) < ($1.path ?? "", $1.message)
        }, cancelled: ScanCancellation.current?.isCancelled == true)
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
        spotlightPresence(bundleID) != .absent
    }

    public static func spotlightPresence(_ bundleID: String) -> OrphanAppPresence {
        spotlightPresence(bundleID, query: { id in
            CommandRunner.run("/usr/bin/mdfind", arguments: ["kMDItemCFBundleIdentifier == '\(id)'"], timeout: 5,
                              outputLimit: 65_536, captureError: false, cancelled: { ScanCancellation.current?.isCancelled == true })
        })
    }

    static func spotlightPresence(_ bundleID: String, query: (String) -> CommandRunner.Result) -> OrphanAppPresence {
        guard isBundleID(bundleID) else { return .unavailable }
        let result = query(bundleID)
        guard result.status == 0, !result.timedOut, !result.cancelled, !result.truncated else { return .unavailable }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .absent : .present
    }

    /// Moves orphaned data to the Trash after checking again that it is still orphaned.
    public static func removeOrphans(_ picked: [OrphanData], home: String = NSHomeDirectory(), installed: [InstalledApp]? = nil,
                                     processes: (() -> ProcessTable)? = nil,
                                     spotlight: (String) -> Bool = spotlightFinds) -> [CleanResult] {
        removeOrphans(picked, home: home, installed: installed, processes: processes, spotlight: spotlight,
                      directories: appDirs(home: home), now: Date(), move: RemovalOperations.live.trash)
    }

    static func removeOrphans(_ picked: [OrphanData], home: String, installed: [InstalledApp]?,
                              processes: (() -> ProcessTable)?, spotlight: (String) -> Bool,
                              directories: [String], now: Date, move: (String) throws -> URL) -> [CleanResult] {
        let table = processes ?? { ProcessTable.current(.init(cpu: false)) }
        let apps = installed ?? AppUninstaller.installed(home: home)
        let known = knownBundleIDs(installed: apps, processes: table())
        let wanted = Set(picked.map(\.bundleID))
        let current = reviewedOrphans(home: home, known: known, now: now, spotlight: { wanted.contains($0) ? spotlight($0) : true },
                                      processes: table(), directories: directories)
        return picked.map { data in
            var result = CleanResult(id: "leftovers:" + data.bundleID, trashed: true)
            let still = current.first { $0.bundleID == data.bundleID }
            if data.blocked != nil || data.ownership?.complete != true || data.dataIdentities == nil {
                result.failed[data.bundleID] = data.blocked ?? tr("Installed apps changed or ownership could not be verified; review associated data again")
            } else if let still, let why = still.blocked {
                result.failed[data.bundleID] = why
            } else if let still, data.ownership != still.ownership {
                result.failed[data.bundleID] = tr("Installed apps changed or ownership could not be verified; review associated data again")
            } else if data.items.contains(where: { data.dataIdentities?[$0.path] == nil || data.dataIdentities?[$0.path] != AppDataReviewIdentity.of($0.path) }) {
                result.failed[data.bundleID] = tr("Associated data changed after review; review it again")
            } else if let still {
                let current = Set(still.items.map(\.path))
                let paths = data.items.map(\.path).filter(current.contains)
                let sizes = Dictionary(uniqueKeysWithValues: still.items.map { ($0.path, $0.bytes) })
                trash(paths, bundleIDs: [data.bundleID], sizes: sizes, home: home, processes: table, into: &result,
                      incompletePaths: Set(still.items.filter { $0.effectiveSizeState != .complete }.map(\.path)),
                      reviewIdentities: data.dataIdentities, ownership: data.ownership, recheckOwnershipEachPath: true, move: move)
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
