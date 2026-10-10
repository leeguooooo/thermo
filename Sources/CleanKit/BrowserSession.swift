import Foundation

/// What happens to an app's windows when Thermo restarts it — checked, never assumed.
///
/// A Chromium browser reopens its tabs only when it is set to "Continue where you left off"
/// (Preferences → session.restore_on_startup = 1, in every profile that is open). Otherwise Thermo
/// saves the tabs before quitting and opens them again after. For any other app Thermo can't know,
/// so it promises nothing.
public enum BrowserSession {
    public enum Windows: String, Codable, Sendable {
        /// The app reopens its windows itself (checked).
        case restoresItself
        /// The browser would lose its tabs; Thermo saves and reopens them.
        case thermoReopensTabs
        /// Unknown: the app may or may not reopen its windows.
        case unknown
    }

    public static func windows(for app: String, home: String = NSHomeDirectory()) -> Windows {
        guard ChromeInspector.isBrowser(app) else { return .unknown }
        return restoresSession(app, home: home) ? .restoresItself : .thermoReopensTabs
    }

    /// True only when every open profile is set to continue where it left off.
    public static func restoresSession(_ app: String, home: String = NSHomeDirectory()) -> Bool {
        guard let dir = ChromeInspector.profileDirs[app] else { return false }
        let root = home + "/Library/Application Support/" + dir
        let state = json(root + "/Local State")?["profile"] as? [String: Any]
        var profiles = state?["last_active_profiles"] as? [String] ?? []
        if profiles.isEmpty { profiles = [state?["last_used"] as? String ?? "Default"] }
        return profiles.allSatisfy { p in
            let session = json(root + "/" + p + "/Preferences")?["session"] as? [String: Any]
            return (session?["restore_on_startup"] as? NSNumber)?.intValue == 1
        }
    }

    /// Preferences files run to a megabyte; read each again only when it changed.
    final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var files: [String: (modified: Date, value: [String: Any]?)] = [:]
    }
    static let cache = Cache()

    static func json(_ path: String) -> [String: Any]? {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return nil }
        cache.lock.lock(); defer { cache.lock.unlock() }
        if let c = cache.files[path], c.modified == modified { return c.value }
        let value = (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        cache.files[path] = (modified, value)
        return value
    }

    // MARK: saving and reopening tabs

    public struct Saved: Codable, Sendable, Equatable {
        public var app: String
        public var saved: Date
        /// Each window's tab addresses, in order.
        public var windows: [[String]]
        public var tabCount: Int { windows.reduce(0) { $0 + $1.count } }
    }

    /// Where the tabs are kept while the browser restarts (and afterwards, in case reopening failed).
    public static func backupURL(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home + "/Library/Application Support/Thermo/restart-tabs.json")
    }

    public static func group(_ tabs: [ChromeInspector.Tab]) -> [[String]] {
        var order: [Int] = []
        var byWindow: [Int: [String]] = [:]
        for t in tabs where !t.url.isEmpty {
            if byWindow[t.window] == nil { order.append(t.window) }
            byWindow[t.window, default: []].append(t.url)
        }
        return order.compactMap { byWindow[$0] }
    }

    /// Lists the browser's tabs and writes them to the backup file. Nil when they can't be listed
    /// (then the browser must not be restarted).
    public static func save(app: String, home: String = NSHomeDirectory()) -> Saved? {
        guard let tabs = ChromeInspector.tabs(app: app) else { return nil }
        let saved = Saved(app: app, saved: Date(), windows: group(tabs))
        let url = backupURL(home: home)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted]
        e.dateEncodingStrategy = .iso8601
        guard (try? e.encode(saved).write(to: url, options: .atomic)) != nil else { return nil }
        return saved
    }

    /// Opens the saved tabs again, one window each, once the browser answers (up to 30 s).
    /// Falls back to opening them all in one window. True when they were opened.
    public static func reopen(_ saved: Saved) -> Bool {
        guard !saved.windows.isEmpty else { return true }
        let data = (try? JSONSerialization.data(withJSONObject: saved.windows)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        let script = """
        const app = Application(\(ChromeInspector.jsString(saved.app)));
        const wins = \(data);
        for (const urls of wins) {
          app.Window().make();
          const w = app.windows[0];
          w.activeTab.url = urls[0];
          for (const u of urls.slice(1)) w.tabs.push(app.Tab({url: u}));
        }
        'ok'
        """
        // Wait until it answers, then open the windows once (a retry could open them twice).
        let ready = "const app = Application(\(ChromeInspector.jsString(saved.app))); app.running() ? String(app.windows.length) : 'no'"
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, ChromeInspector.osascript(ready).flatMap(Int.init) == nil { Thread.sleep(forTimeInterval: 1) }
        if ChromeInspector.osascript(script) == "ok" { return true }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", saved.app] + saved.windows.flatMap { $0 }
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
