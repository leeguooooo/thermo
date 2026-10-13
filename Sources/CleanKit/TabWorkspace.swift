import Foundation
import Darwin
import AgentCore

/// User-owned tab groups and recoverable batches, shared by the GUI and CLI. Browser tab IDs
/// are tied to the browser process lifetime; saved pages use independent UUIDs.
public enum TabWorkspace {
    public struct Page: Codable, Sendable, Identifiable, Equatable {
        public var tab: ChromeInspector.Tab
        public var group: String
        public var color: String?
        public var protectedReason: String?
        public var id: String { tab.selectionID }
        public var canArchive: Bool { protectedReason == nil && tab.canSelect && tab.active == false }
        enum OutputKeys: String, CodingKey { case id, tab, group, color, protectedReason }
        public func encode(to encoder: Encoder) throws {
            var out = encoder.container(keyedBy: OutputKeys.self)
            try out.encode(id, forKey: .id); try out.encode(tab, forKey: .tab)
            try out.encode(group, forKey: .group); try out.encodeIfPresent(color, forKey: .color)
            try out.encodeIfPresent(protectedReason, forKey: .protectedReason)
        }
    }
    public struct Inventory: Codable, Sendable {
        public var app: String
        public var generated: Date
        public var pages: [Page]
        public var hint: String?
    }
    public struct Entry: Codable, Sendable, Identifiable {
        public var id: UUID = UUID()
        public var page: Page
        public var status: String = "pending"
        public var restoredID: String?
        public var restoreState: String? = nil
    }
    public struct Archive: Codable, Sendable, Identifiable {
        public var schema: Int = 1
        public var id: UUID = UUID()
        public var name: String
        public var app: String
        public var saved: Date = Date()
        public var entries: [Entry]
        public var closed: Int { entries.filter { $0.status == "closed" }.count }
        public var remaining: Int { entries.filter { $0.status == "closed" && $0.restoreState == nil }.count }
    }
    public struct Groups: Codable {
        public var assignments: [String: String] = [:]
        public init() {}
    }
    public struct WorkspaceError: Error, LocalizedError, CustomStringConvertible {
        public var description: String
        public var errorDescription: String? { description }
        public init(_ message: String) { description = message }
    }
    public static func directory(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home + "/Library/Application Support/Thermo/TabWorkspace", isDirectory: true)
    }
    public static func site(_ url: String) -> String {
        URL(string: url)?.host?.lowercased() ?? "Other"
    }
    static func isWeb(_ url: String) -> Bool {
        guard let u = URL(string: url), ["http", "https"].contains(u.scheme?.lowercased() ?? ""), u.host != nil else { return false }
        return true
    }

    /// No renderer attachments. AppleScript supplies native identities, the relay supplies
    /// protection flags where available. Unknown protection metadata stays out of quick archive.
    public static func inventory(app: String = "Google Chrome", home: String = NSHomeDirectory()) async throws -> Inventory {
        guard ChromeInspector.isBrowser(app), let tabs = ChromeInspector.tabs(app: app) else {
            throw WorkspaceError("Cannot read browser tabs. Check Thermo's Automation permission.")
        }
        let assignments = try groups(home: home).assignments
        var records: [String: [String: Any]] = [:]
        var nativeGroups: [Int: [String: Any]] = [:]
        var owned = Set<String>()
        var agentWindows = Set<Int>()
        var metadata = false
        if let endpoint = ChromeInspector.endpoint(app: app, home: home) {
            let cdp = ChromeInspector.CDP(endpoint, diagnostic: true)
            defer { cdp.close() }
            if let response = await cdp.send("ABExt.call", ["namespace": "tabs", "method": "query", "args": [[:]]]),
               let rows = response["result"] as? [[String: Any]],
               let state = await cdp.send("ABExt.state"),
               let held = state["ownedTabs"] as? [Int], let attached = state["attachedTargets"] as? [[String: Any]] {
                metadata = true
                if let window = state["agentWindowId"] as? Int { agentWindows.insert(window) }
                owned.formUnion(held.map(String.init))
                for row in attached {
                    if let id = row["tabId"] as? Int { owned.insert(String(id)) }
                }
                for row in rows {
                    if let id = row["id"] as? Int { records[String(id)] = row }
                }
                if let response = await cdp.send("ABExt.call", ["namespace": "tabGroups", "method": "query", "args": [[:]]]),
                   let rows = response["result"] as? [[String: Any]] {
                    for row in rows { if let id = row["id"] as? Int { nativeGroups[id] = row } }
                }
            }
        }
        let pages = (tabs.filter { !agentWindows.contains($0.window) } + tabs.filter { agentWindows.contains($0.window) }).map { tab -> Page in
            let row = records[tab.browserID ?? ""]
            let matches = row?["url"] as? String == tab.url && row?["windowId"] as? Int == tab.window
            let groupID = row?["groupId"] as? Int ?? -1
            let native = nativeGroups[groupID]
            let group = assignments[tab.selectionID] ?? (matches ? native?["title"] as? String : nil) ?? site(tab.url)
            let reason = protection(tab, row: matches ? row : nil, owned: owned, metadata: metadata, agentWindows: agentWindows)
            return Page(tab: tab, group: group.isEmpty ? site(tab.url) : group, color: native?["color"] as? String, protectedReason: reason)
        }
        return Inventory(app: app, generated: Date(), pages: pages,
                         hint: metadata ? nil : "Connect chrome-use to read pinned, audio and agent protection status. Quick archive is disabled until those flags are known.")
    }

    static func protection(_ tab: ChromeInspector.Tab, row: [String: Any]?, owned: Set<String>, metadata: Bool, agentWindows: Set<Int> = []) -> String? {
        if !tab.canSelect { return "Tab identity unavailable" }
        if tab.active != false || row?["active"] as? Bool == true { return "Current tab" }
        if !isWeb(tab.url) { return "Browser or local page" }
        if !metadata || row == nil { return "Protection status unavailable" }
        if agentWindows.contains(tab.window) || owned.contains(tab.browserID ?? "") { return "Used by an agent or debugger" }
        if row?["incognito"] as? Bool != false { return "Private browsing" }
        if row?["pinned"] as? Bool != false { return "Pinned tab" }
        if row?["audible"] as? Bool != false { return "Playing audio" }
        return nil
    }

    /// One passive connection per batch and constant-size per-page metadata calls. No repeated
    /// enumeration of every browser tab while closing a large batch.
    static func live(_ page: Page, app: String, cdp: ChromeInspector.CDP?) async throws -> Inventory {
        guard let cdp, let raw = page.tab.browserID, let id = Int(raw),
              let process = page.tab.browserProcess, process == ProcessTable.identity(process.pid) else {
            throw WorkspaceError("The original browser session is unavailable.")
        }
        let (response, error) = await cdp.call("ABExt.call", ["namespace": "tabs", "method": "get", "args": [id]])
        if let error, error.contains("No tab with id: \(id).") {
            return Inventory(app: app, generated: Date(), pages: [])
        }
        guard error == nil, let row = response?["result"] as? [String: Any],
              let state = await cdp.send("ABExt.state"), let ids = state["ownedTabs"] as? [Int],
              let attached = state["attachedTargets"] as? [[String: Any]] else {
            throw WorkspaceError("Cannot recheck tab protection status.")
        }
        var owned = Set(ids.map(String.init))
        for held in attached { if let id = held["tabId"] as? Int { owned.insert(String(id)) } }
        var current = page
        current.tab.url = row["url"] as? String ?? ""
        current.tab.title = row["title"] as? String ?? ""
        current.tab.active = row["active"] as? Bool
        current.tab.window = row["windowId"] as? Int ?? 0
        let windows = Set((state["agentWindowId"] as? Int).map { [$0] } ?? [])
        current.protectedReason = protection(current.tab, row: row, owned: owned, metadata: true, agentWindows: windows)
        return Inventory(app: app, generated: Date(), pages: [current])
    }

    public static func groups(home: String = NSHomeDirectory()) throws -> Groups {
        let url = directory(home: home).appendingPathComponent("groups.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Groups() }
        return try JSONDecoder().decode(Groups.self, from: Data(contentsOf: url))
    }
    /// Thermo groups do not move tabs between browser windows or change another agent's groups.
    public static func assign(_ pages: [Page], name: String?, home: String = NSHomeDirectory()) throws {
        let lock = try Lock(home: home); defer { lock.release() }
        var value = try groups(home: home)
        if let name, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw WorkspaceError("Group name is empty.") }
        for page in pages {
            if let name { value.assignments[page.id] = name } else { value.assignments[page.id] = site(page.tab.url) }
        }
        try write(value, to: directory(home: home).appendingPathComponent("groups.json"))
    }
    public static func archives(home: String = NSHomeDirectory()) throws -> [Archive] {
        let dir = directory(home: home)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "groups.json" }
            .map { try read($0) }.sorted { $0.saved > $1.saved }
    }
    public static func archiveURL(_ id: UUID, home: String = NSHomeDirectory()) -> URL {
        directory(home: home).appendingPathComponent(id.uuidString + ".json")
    }
    static func read(_ url: URL) throws -> Archive {
        let value = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: url))
        guard value.schema == 1 else { throw WorkspaceError("Unsupported saved tab schema.") }
        return value
    }
    /// Atomic owner-only writes, flushed and read back before any browser mutation.
    static func write<T: Codable>(_ value: T, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".write-" + UUID().uuidString)
        let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw WorkspaceError("Cannot open saved tab record.") }
        defer { Darwin.close(fd); try? fm.removeItem(at: temporary) }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw WorkspaceError("Cannot write saved tab record.") }
                written += n
            }
        }
        guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else { throw WorkspaceError("Cannot flush saved tab record.") }
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
        guard parent >= 0 else { throw WorkspaceError("Cannot flush saved tab directory.") }
        defer { Darwin.close(parent) }
        guard fsync(parent) == 0, try Data(contentsOf: url) == data else { throw WorkspaceError("Cannot verify saved tab record. Nothing closed.") }
    }
    final class Lock {
        let fd: Int32
        init(home: String) throws {
            let dir = directory(home: home)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            fd = open(dir.appendingPathComponent("workspace.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw WorkspaceError("Cannot lock tab workspace.") }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw WorkspaceError("Another tab operation is running. Wait for it to finish.") }
        }
        func release() { flock(fd, LOCK_UN) }
        deinit { Darwin.close(fd) }
    }

    public typealias ReadInventory = @Sendable (String) async throws -> Inventory
    public typealias ClosePages = @Sendable ([ChromeInspector.Tab], String) -> [ChromeInspector.TabCloseResult]
    public static func archive(_ selected: [Page], app: String, name: String, home: String = NSHomeDirectory(),
                               readInventory: ReadInventory? = nil, close: ClosePages? = nil) async throws -> Archive {
        let lock = try Lock(home: home); defer { lock.release() }
        guard !selected.isEmpty, Set(selected.map(\.id)).count == selected.count,
              selected.allSatisfy(\.canArchive) else { throw WorkspaceError("Choose unprotected background tabs before saving and closing.") }
        let connection = readInventory == nil ? ChromeInspector.endpoint(app: app, home: home).map { ChromeInspector.CDP($0, diagnostic: true) } : nil
        defer { connection?.close() }
        let close = close ?? { ChromeInspector.closeTabs($0, app: $1) }
        var archive = Archive(name: name.isEmpty ? "Saved tabs" : name, app: app, entries: selected.map { Entry(page: $0) })
        let url = archiveURL(archive.id, home: home)
        try write(archive, to: url)
        // Check live metadata immediately before each close. No URL fallback, no retries after
        // unknown delivery. Journal 'closing' first so a crash leaves a recoverable uncertainty.
        for i in archive.entries.indices {
            let page = archive.entries[i].page
            let current = try await (readInventory.map { reader in { try await reader(app) } } ?? { try await live(page, app: app, cdp: connection) })()
            guard let refreshed = current.pages.first(where: { $0.id == page.id }), refreshed.canArchive,
                  refreshed.tab.url == page.tab.url, refreshed.tab.title == page.tab.title, refreshed.tab.window == page.tab.window else {
                archive.entries[i].status = "skipped"
                try write(archive, to: url); continue
            }
            archive.entries[i].status = "closing"; try write(archive, to: url)
            let result = close([page.tab], app)
            let after = try? await (readInventory.map { reader in { try await reader(app) } } ?? { try await live(page, app: app, cdp: connection) })()
            if let after {
                archive.entries[i].status = after.pages.contains(where: { $0.id == page.id }) ? "skipped" : "closed"
            } else {
                archive.entries[i].status = result.first?.status == .missing ? "skipped" : "unconfirmed"
            }
            try write(archive, to: url)
        }
        return archive
    }

    public typealias OpenPage = @Sendable (Page, String) -> String?
    /// Restore each confirmed closed page once. Persist 'opening' before sending a mutation:
    /// unknown delivery stays explicit and is never automatically retried.
    public static func restore(_ id: UUID, destinationWindow: Int? = nil, home: String = NSHomeDirectory(),
                               openPage: OpenPage? = nil) throws -> Archive {
        let lock = try Lock(home: home); defer { lock.release() }
        let url = archiveURL(id, home: home)
        var archive = try read(url)
        let opener = openPage ?? { reopen($0, $1) }
        for i in archive.entries.indices where archive.entries[i].status == "closed" && archive.entries[i].restoreState == nil {
            var page = archive.entries[i].page
            if let destinationWindow {
                guard let tabs = ChromeInspector.tabs(app: archive.app), let destination = tabs.first(where: { $0.window == destinationWindow }) else { throw WorkspaceError("Destination window is not available.") }
                page.tab.window = destinationWindow; page.tab.browserProcess = destination.browserProcess
            }
            guard isWeb(page.tab.url) else { throw WorkspaceError("Saved page is not a web URL.") }
            // AppleScript can target the original profile only while its original window exists.
            if openPage == nil {
                guard page.tab.browserProcess == ChromeInspector.browserIdentity(app: archive.app) else {
                    throw WorkspaceError("The original browser session ended. Open a saved link in the correct profile manually; automatic restore will not guess the profile.")
                }
            }
            archive.entries[i].restoreState = "opening"; try write(archive, to: url)
            if let browserID = opener(page, archive.app) {
                archive.entries[i].restoredID = browserID
                archive.entries[i].restoreState = "restored"
                var g = try groups(home: home)
                var t = page.tab; t.browserID = browserID
                g.assignments[t.selectionID] = page.group
                try write(g, to: directory(home: home).appendingPathComponent("groups.json"))
            } else { archive.entries[i].restoreState = "unconfirmed" }
            try write(archive, to: url)
        }
        return archive
    }
    static func reopen(_ page: Page, _ app: String, execute: ((String) -> String?)? = nil) -> String? {
        let script = """
        const app = Application(\(ChromeInspector.jsString(app)));
        if (!app.running()) { '' } else {
          const windows = app.windows().filter(w => String(w.id()) === \(ChromeInspector.jsString(String(page.tab.window))));
          if (windows.length !== 1) { '' } else {
            const w = windows[0];
            const current = w.activeTabIndex();
            const before = new Set(w.tabs().map(x => String(x.id())));
            const t = app.Tab({url: \(ChromeInspector.jsString(page.tab.url))});
            w.tabs.push(t);
            w.activeTabIndex = current;
            const found = w.tabs().filter(x => !before.has(String(x.id())) && x.url() === \(ChromeInspector.jsString(page.tab.url)));
            found.length === 1 ? String(found[0].id()) : '';
          }
        }
        """
        return (execute ?? ChromeInspector.osascript)(script).flatMap { $0.isEmpty ? nil : $0 }
    }
}
