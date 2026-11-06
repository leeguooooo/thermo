import Foundation
import AgentCore
import ThermoL10n

/// Plans website/rule groups without reading page contents, then asks the extension to perform
/// guarded native Chrome grouping. No debugger attachment, account switch or URL adoption.
public enum TabOrganizer {
    public struct Rule: Codable, Sendable, Identifiable, Equatable {
        public var id = UUID()
        public var domain: String
        public var name: String
        public var color: String
        public init(domain: String, name: String, color: String = "blue") { self.domain = domain; self.name = name; self.color = color }
    }
    public struct Configuration: Codable, Sendable {
        public var enabled = false
        public var rules: [Rule] = []
        public init() {}
    }
    public struct Group: Codable, Sendable, Identifiable {
        public var id: String
        public var profileID: String
        public var window: Int
        public var name: String
        public var color: String
        public var pages: [TabWorkspace.Page]
        /// A group Thermo made earlier in this window, still there with this name: the pages join it.
        public var groupId: Int? = nil
    }
    public struct Plan: Codable, Sendable {
        public var app: String
        public var groups: [Group]
        public var unsupported: Int
        public var count: Int
        /// Sites left alone because their Thermo group exists and this chrome-use cannot add to it.
        public var waitingForJoin: Int? = nil
    }
    public struct Outcome: Codable, Sendable {
        public var tabId: Int
        public var groupId: Int?
        public var status: String
    }
    public struct Reply: Codable, Sendable {
        public var version: Int
        public var id: String
        public var phase: String
        public var results: [Outcome]
        public var undoResults: [Outcome]?
    }
    public struct Batch: Codable, Sendable, Identifiable {
        public var id = UUID()
        public var created = Date()
        public var app: String
        public var plan: Plan
        public var requests: [String: String] = [:]
        public var replies: [String: Reply] = [:]
        public var errors: [String: String] = [:]
        public var undoAttempted: Set<String> = []
        public var grouped: Int { replies.values.flatMap(\.results).filter { $0.status == "grouped" }.count }
        public var restored: Int { replies.values.flatMap { $0.undoResults ?? [] }.filter { $0.status == "restored" }.count }
    }
    public static let colors = ["blue", "green", "orange", "purple", "cyan", "red", "yellow", "pink", "grey"]
    static func root(_ home: String) -> URL { TabWorkspace.directory(home: home).appendingPathComponent("Organizer", isDirectory: true) }
    public static func configuration(home: String = NSHomeDirectory()) throws -> Configuration {
        let url = root(home).appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Configuration() }
        return try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
    }
    public static func configure(_ config: Configuration, home: String = NSHomeDirectory()) throws {
        guard config.rules.allSatisfy({ valid($0) }) else { throw TabWorkspace.WorkspaceError("Rules need a domain, group name and supported color.") }
        let lock = try TabWorkspace.Lock(home: home); defer { lock.release() }
        try TabWorkspace.write(config, to: root(home).appendingPathComponent("settings.json"))
    }
    static func valid(_ rule: Rule) -> Bool {
        let host = rule.domain.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return !host.isEmpty && !host.contains("/") && !host.contains(":") && !host.contains(" ") &&
            !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && rule.name.count <= 100 && colors.contains(rule.color)
    }
    static func matching(_ host: String, _ rule: Rule) -> Bool {
        let domain = rule.domain.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return host == domain || host.hasSuffix("." + domain)
    }
    /// `batches`: earlier runs, so a site that already has a Thermo group gets added to it rather
    /// than given a second group. `auto`: the every-minute run, which never adds a duplicate.
    public static func plan(_ inventory: TabWorkspace.Inventory, pages: [TabWorkspace.Page]? = nil, rules: [Rule] = [],
                            batches: [Batch] = [], auto: Bool = false) -> Plan {
        let pages = pages ?? inventory.pages
        let existing = madeByThermo(batches, current: inventory.nativeGroups ?? [])
        var grouped: [String: Group] = [:]
        var unsupported = 0
        var explicit = Set<String>()
        var skipped = Set<String>()
        for page in pages {
            guard page.canArchive, page.nativeGroupID == -1 else { continue }
            guard page.organizerVersion == 1, let profile = page.profileID else { unsupported += 1; continue }
            let host = TabWorkspace.site(page.tab.url)
            let rule = rules.first { valid($0) && matching(host, $0) }
            var name = rule?.name ?? siteName(host)
            // A group Thermo made earlier for this site keeps receiving its tabs, whatever it was titled
            // then (a full host, or the name in another language).
            let prefix = profile + ":" + String(page.tab.window) + ":"
            if rule == nil, existing[prefix + name] == nil {
                let key = siteKey(host)
                if let old = existing.keys.filter({ $0.hasPrefix(prefix) }).map({ String($0.dropFirst(prefix.count)) })
                    .sorted().first(where: { titleKey($0) == key }) { name = old }
            }
            // Colored by the site, not the title, so a group keeps its color in every language.
            var hash: UInt64 = 14695981039346656037
            for byte in (rule?.name ?? siteKey(host)).utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
            var color = rule?.color ?? colors[Int(hash % UInt64(colors.count))]
            let key = profile + ":" + String(page.tab.window) + ":" + name
            var target: Int?
            if let group = existing[key] {
                if page.organizerCanJoin == true {
                    target = group.id
                    if let c = group.color, colors.contains(c) { color = c }
                } else if auto {
                    // This extension cannot add to the existing group; a second one every minute is worse.
                    skipped.insert(key); continue
                }
            }
            if rule != nil || target != nil { explicit.insert(key) }
            if grouped[key] == nil {
                grouped[key] = Group(id: key, profileID: profile, window: page.tab.window, name: name, color: color, pages: [], groupId: target)
            }
            grouped[key]!.pages.append(page)
        }
        // Avoid turning every lone website into a one-tab group. Explicit custom rules may group one,
        // and one new tab may join its site's existing group.
        let groups = grouped.values.filter { group in group.pages.count >= 2 || explicit.contains(group.id) }
            .sorted { ($0.window, $0.name) < ($1.window, $1.name) }
        return Plan(app: inventory.app, groups: groups, unsupported: unsupported,
                    count: groups.reduce(0) { $0 + $1.pages.count }, waitingForJoin: skipped.count)
    }

    /// The group a website's tabs go into: one per site, not per subdomain (zentao.example.cc and
    /// git.example.cc are one site), named the way people call it, in the app's language
    /// ("Lark" is 飞书 in Chinese). Google's separate products keep their own groups.
    public static func siteName(_ host: String) -> String { tr(siteKey(host)) }

    /// The language-neutral name behind `siteName`: a known product name, or the site's own name
    /// without its suffix and capitalized (zegocloud.com → Zegocloud). Hosts that are not a site
    /// (an address, localhost) and hosting subdomains (alice.github.io) stay as they are.
    static func siteKey(_ host: String) -> String {
        var host = host.lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count >= 2, Int(labels.last!) == nil else { return host }
        let hosting: Set<String> = ["github.io", "pages.dev", "workers.dev", "vercel.app", "netlify.app", "herokuapp.com", "appspot.com", "cloudfront.net"]
        let twoLevel: Set<String> = hosting.union(["co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp", "ed.jp", "lg.jp", "gr.jp",
                                     "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "com.hk", "com.tw", "org.tw", "edu.tw",
                                     "co.uk", "org.uk", "ac.uk", "gov.uk", "com.au", "net.au", "org.au", "co.kr", "or.kr",
                                     "com.sg", "edu.sg", "co.nz", "com.br", "co.in"])
        let suffix2 = labels.suffix(2).joined(separator: ".")
        let multi = twoLevel.contains(suffix2) && labels.count >= 3
        let site = multi ? labels.suffix(3).joined(separator: ".") : suffix2
        if hosting.contains(suffix2) { return site }
        if site == "google.com" {
            let product = labels.count > 2 ? labels[labels.count - 3] : ""
            return googleProducts[product] ?? "Google"
        }
        if let known = knownSites[site] { return known }
        // The site's own name: the label before its suffix.
        let name = multi ? labels[labels.count - 3] : labels[labels.count - 2]
        guard name.count > 3 else { return site }  // "moj", "ntt": too short to read as a name
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    static let googleProducts = ["docs": "Google Docs", "sheets": "Google Docs", "slides": "Google Docs", "drive": "Google Drive",
                                 "mail": "Gmail", "calendar": "Google Calendar", "meet": "Google Meet", "cloud": "Google Cloud",
                                 "translate": "Google Translate", "maps": "Google Maps", "analytics": "Google Analytics"]
    static let knownSites = ["github.com": "GitHub", "githubusercontent.com": "GitHub", "gitlab.com": "GitLab", "youtube.com": "YouTube",
                             "youtu.be": "YouTube", "x.com": "X", "twitter.com": "X", "larksuite.com": "Lark", "feishu.cn": "Lark",
                             "notion.so": "Notion", "notion.site": "Notion", "figma.com": "Figma", "slack.com": "Slack",
                             "stackoverflow.com": "Stack Overflow", "wikipedia.org": "Wikipedia", "reddit.com": "Reddit",
                             "openai.com": "OpenAI", "chatgpt.com": "ChatGPT", "claude.ai": "Claude", "anthropic.com": "Anthropic",
                             "apple.com": "Apple", "amazon.com": "Amazon", "amazon.co.jp": "Amazon", "zhihu.com": "Zhihu",
                             "bilibili.com": "bilibili", "baidu.com": "Baidu", "weibo.com": "Weibo", "xiaohongshu.com": "Xiaohongshu",
                             "mercari.com": "Mercari", "cloudflare.com": "Cloudflare", "vercel.com": "Vercel", "linear.app": "Linear",
                             "atlassian.net": "Jira", "medium.com": "Medium", "npmjs.com": "npm", "docker.com": "Docker",
                             "zegocloud.com": "ZEGOCLOUD"]

    /// The language-neutral name an existing group title stands for, whether the title is a host
    /// (groups named before site names existed) or a name in any language Thermo has used.
    static func titleKey(_ title: String) -> String {
        if title.contains("."), !title.contains(" ") { return siteKey(title) }
        let names = Set(googleProducts.values).union(knownSites.values)
        if let key = names.first(where: { $0 == title || tr($0) == title }) { return key }
        return title
    }

    /// A group Thermo made under a name that is not the site's name in the current language
    /// (a bare host, or the name in another language), and what it should be called.
    public struct Rename: Codable, Sendable, Identifiable, Equatable {
        public var id: String { profileID + ":" + String(groupId) }
        public var profileID: String
        public var groupId: Int
        public var from: String
        public var to: String
    }

    /// Groups Thermo made whose title should become the site's name. Groups named by a website rule
    /// or by the user are never listed: their titles are not a host or a known site name.
    public static func renames(_ inventory: TabWorkspace.Inventory, batches: [Batch]) -> [Rename] {
        let profiles = Set(inventory.renameProfiles ?? [])
        guard !profiles.isEmpty else { return [] }
        return madeByThermo(batches, current: inventory.nativeGroups ?? []).values.compactMap { group in
            guard profiles.contains(group.profileID) else { return nil }
            let key = titleKey(group.title)
            // Only titles that name a site: a bare host, or a known site's name in some language.
            // A name from a website rule or the user ("Work") is theirs and stays.
            let known = Set(googleProducts.values).union(knownSites.values)
            let isSiteTitle = (group.title.contains(".") && !group.title.contains(" ")) || known.contains(key)
            let name = tr(key)
            guard isSiteTitle, name != group.title, !name.isEmpty else { return nil }
            return Rename(profileID: group.profileID, groupId: group.id, from: group.title, to: name)
        }.sorted { $0.from < $1.from }
    }

    /// Renames through chrome-use, which re-checks each group is Thermo's and still titled `from`.
    public static func rename(_ renames: [Rename], app: String, home: String = NSHomeDirectory(), execute: Execute? = nil) async throws -> Int {
        let lock = try TabWorkspace.Lock(home: home); defer { lock.release() }
        let endpoints = TabWorkspace.connections(app: app, home: home)
        var renamed: [Rename] = [], failures: [String] = []
        for profile in Set(renames.map(\.profileID)).sorted() {
            let rows = renames.filter { $0.profileID == profile }
            let payload: [String: Any] = ["version": 1, "id": UUID().uuidString, "reviewed": true,
                                          "groups": rows.map { ["groupId": $0.groupId, "from": $0.from, "to": $0.to] as [String: Any] }]
            do {
                let results: [[String: Any]]
                if let execute {
                    _ = try await execute("ABExt.renameUserTabGroups", payload, profile); results = rows.map { ["groupId": $0.groupId, "status": "renamed"] }
                } else {
                    guard let endpoint = endpoints[profile] else { throw TabWorkspace.WorkspaceError("Browser profile disconnected. Nothing renamed.") }
                    let client = ChromeInspector.CDP(endpoint, diagnostic: true); defer { client.close() }
                    guard let reply = await client.send("ABExt.renameUserTabGroups", payload), let r = reply["results"] as? [[String: Any]] else {
                        throw TabWorkspace.WorkspaceError("chrome-use did not answer the rename request.")
                    }
                    results = r
                }
                let done = Set(results.filter { $0["status"] as? String == "renamed" }.compactMap { $0["groupId"] as? Int })
                renamed += rows.filter { done.contains($0.groupId) }
            } catch { failures.append(error.localizedDescription) }
        }
        if !renamed.isEmpty {
            OperationJournal.record(OperationRecord(feature: "tabs", action: "rename", subject: app,
                                                    items: renamed.map { OperationRecord.Item(target: $0.from + " → " + $0.to, status: "done") }), home: home)
        }
        if renamed.isEmpty, let first = failures.first { throw TabWorkspace.WorkspaceError(first) }
        return renamed.count
    }

    /// Groups Thermo itself made (from its batch records, never from a title match alone: chrome-use
    /// names agent session groups too), keyed like plan groups by their current title, that still
    /// exist in the same window under a title for the same site. Newest first wins.
    static func madeByThermo(_ batches: [Batch], current: [TabWorkspace.NativeGroup]) -> [String: TabWorkspace.NativeGroup] {
        var result: [String: TabWorkspace.NativeGroup] = [:]
        for batch in batches.sorted(by: { $0.created > $1.created }) {
            for group in batch.plan.groups {
                let tabs = Set(group.pages.compactMap { Int($0.tab.browserID ?? "") })
                let ids = Set((batch.replies[group.profileID]?.results ?? [])
                    .filter { $0.status == "grouped" && tabs.contains($0.tabId) }.compactMap(\.groupId))
                // Matched by id, keyed by the title it has now: a group Thermo renamed to the site's name
                // is still Thermo's, and new tabs must join it under that name.
                // The title must still stand for the same site, so a group id Chrome reused after a restart
                // for one of the user's own groups is never taken for Thermo's.
                if let live = current.first(where: { ids.contains($0.id) && $0.profileID == group.profileID && $0.window == group.window
                                                    && titleKey($0.title) == titleKey(group.name) }) {
                    let key = group.profileID + ":" + String(group.window) + ":" + live.title
                    if result[key] == nil { result[key] = live }
                }
            }
        }
        return result
    }
    public static func batches(home: String = NSHomeDirectory()) throws -> [Batch] {
        let directory = root(home)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("batch-") && $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(Batch.self, from: Data(contentsOf: $0)) }.sorted { $0.created > $1.created }
    }
    static func url(_ id: UUID, home: String) -> URL { root(home).appendingPathComponent("batch-" + id.uuidString + ".json") }
    public typealias Execute = @Sendable (String, [String: Any], String) async throws -> Reply
    static func send(_ method: String, payload: [String: Any], client: ChromeInspector.CDP) async throws -> Reply {
        let (result, error) = await client.call(method, payload)
        guard error == nil, let result, let data = try? JSONSerialization.data(withJSONObject: result),
              let reply = try? JSONDecoder().decode(Reply.self, from: data), reply.version == 1 else {
            throw TabWorkspace.WorkspaceError(error ?? "Native tab grouping is unavailable. Update the chrome-use extension to 0.5.48 or newer.")
        }
        return reply
    }
    public static func organize(_ plan: Plan, home: String = NSHomeDirectory(), execute: Execute? = nil) async throws -> Batch {
        let lock = try TabWorkspace.Lock(home: home); defer { lock.release() }
        guard plan.count > 0, plan.count <= 1000 else { throw TabWorkspace.WorkspaceError("Choose 1–1000 supported background tabs for native grouping.") }
        let endpoints = TabWorkspace.connections(app: plan.app, home: home)
        var batch = Batch(app: plan.app, plan: plan)
        let file = url(batch.id, home: home)
        for profile in Set(plan.groups.map(\.profileID)) { batch.requests[profile] = UUID().uuidString }
        try TabWorkspace.write(batch, to: file)
        for (profile, id) in batch.requests.sorted(by: { $0.key < $1.key }) {
            let groups = plan.groups.filter { $0.profileID == profile }
            let pages = groups.flatMap(\.pages)
            guard pages.allSatisfy({ $0.tab.browserProcess.map { $0 == ProcessTable.identity($0.pid) } ?? false }) || execute != nil else {
                batch.errors[profile] = "Browser session changed; grouping skipped."; try TabWorkspace.write(batch, to: file); continue
            }
            let payload: [String: Any] = ["version": 1, "id": id, "reviewed": true, "groups": groups.map { group in
                var row: [String: Any] = ["name": group.name, "color": group.color, "tabs": group.pages.map { page in
                    ["id": Int(page.tab.browserID ?? "") ?? -1, "windowId": page.tab.window, "index": page.tab.index - 1, "url": page.tab.url, "title": page.tab.title] as [String: Any]
                }]
                if let target = group.groupId { row["groupId"] = target }
                return row
            }]
            do {
                let reply: Reply
                if let execute { reply = try await execute("ABExt.organizeUserTabs", payload, profile) }
                else {
                    guard let endpoint = endpoints[profile] else { throw TabWorkspace.WorkspaceError("Browser profile disconnected. Nothing grouped.") }
                    let client = ChromeInspector.CDP(endpoint, diagnostic: true); defer { client.close() }
                    reply = try await send("ABExt.organizeUserTabs", payload: payload, client: client)
                }
                guard reply.id == id, reply.results.count == pages.count, Set(reply.results.map(\.tabId)) == Set(pages.compactMap { Int($0.tab.browserID ?? "") }) else { throw TabWorkspace.WorkspaceError("Grouping reply could not be matched to the reviewed batch.") }
                batch.replies[profile] = reply
                if reply.results.contains(where: { $0.status == "unconfirmed" }) { batch.errors[profile] = "Some native grouping results are unconfirmed. Check Chrome before trying again." }
                // The extension makes a new group when it cannot join the one asked for; say so instead of
                // reporting a second same-name group as success.
                let missed = groups.filter { group in
                    guard let target = group.groupId else { return false }
                    let tabs = Set(group.pages.compactMap { Int($0.tab.browserID ?? "") })
                    return reply.results.contains { tabs.contains($0.tabId) && $0.status == "grouped" && $0.groupId != target }
                }
                if !missed.isEmpty, batch.errors[profile] == nil {
                    batch.errors[profile] = "Could not join the existing group for " + missed.map(\.name).joined(separator: ", ") + "; a second group was made. Update chrome-use, then undo this batch and organize again."
                }
            } catch { batch.errors[profile] = error.localizedDescription }
            try TabWorkspace.write(batch, to: file)
        }
        journal(batch, action: "organize", home: home)
        return batch
    }
    public static func undo(_ id: UUID, home: String = NSHomeDirectory(), execute: Execute? = nil) async throws -> Batch {
        let lock = try TabWorkspace.Lock(home: home); defer { lock.release() }
        let file = url(id, home: home)
        var batch = try JSONDecoder().decode(Batch.self, from: Data(contentsOf: file))
        let endpoints = TabWorkspace.connections(app: batch.app, home: home)
        for (profile, request) in batch.requests.sorted(by: { $0.key < $1.key }) where !batch.undoAttempted.contains(profile) {
            if execute == nil, endpoints[profile] == nil {
                batch.errors[profile] = "Browser profile disconnected."
                try TabWorkspace.write(batch, to: file)
                continue
            }
            batch.undoAttempted.insert(profile); try TabWorkspace.write(batch, to: file)
            let payload: [String: Any] = ["version": 1, "id": request, "reviewed": true]
            do {
                if let execute { batch.replies[profile] = try await execute("ABExt.undoOrganizeUserTabs", payload, profile) }
                else {
                    guard let endpoint = endpoints[profile] else { continue }
                    let client = ChromeInspector.CDP(endpoint, diagnostic: true); defer { client.close() }
                    batch.replies[profile] = try await send("ABExt.undoOrganizeUserTabs", payload: payload, client: client)
                }
            } catch { batch.errors[profile] = error.localizedDescription }
            try TabWorkspace.write(batch, to: file)
        }
        journal(batch, action: "undoOrganize", home: home)
        return batch
    }
    static func journal(_ batch: Batch, action: String, home: String) {
        var items = batch.plan.groups.map { group in
            OperationRecord.Item(target: group.name, status: batch.errors[group.profileID] == nil ? "done" : "failed",
                                 detail: batch.errors[group.profileID] ?? String(group.pages.count))
        }
        if items.isEmpty { items = batch.errors.map { .init(target: $0.key, status: "failed", detail: $0.value) } }
        OperationJournal.record(OperationRecord(feature: "tabs", action: action, subject: batch.app, items: items,
                                                undo: action == "organize" ? .init(kind: "tabBatch", ref: batch.id.uuidString) : nil), home: home)
    }
}
