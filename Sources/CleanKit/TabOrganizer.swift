import Foundation
import AgentCore

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
    }
    public struct Plan: Codable, Sendable {
        public var app: String
        public var groups: [Group]
        public var unsupported: Int
        public var count: Int
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
    public static func plan(_ inventory: TabWorkspace.Inventory, pages: [TabWorkspace.Page]? = nil, rules: [Rule] = []) -> Plan {
        let pages = pages ?? inventory.pages
        var grouped: [String: Group] = [:]
        var unsupported = 0
        var explicit = Set<String>()
        for page in pages {
            guard page.canArchive, page.nativeGroupID == -1 else { continue }
            guard page.organizerVersion == 1, let profile = page.profileID else { unsupported += 1; continue }
            let host = TabWorkspace.site(page.tab.url)
            let rule = rules.first { valid($0) && matching(host, $0) }
            let name = rule?.name ?? host
            var hash: UInt64 = 14695981039346656037
            for byte in name.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
            let color = rule?.color ?? colors[Int(hash % UInt64(colors.count))]
            let key = profile + ":" + String(page.tab.window) + ":" + name
            if rule != nil { explicit.insert(key) }
            if grouped[key] == nil { grouped[key] = Group(id: key, profileID: profile, window: page.tab.window, name: name, color: color, pages: []) }
            grouped[key]!.pages.append(page)
        }
        // Avoid turning every lone website into a one-tab group. Explicit custom rules may group one.
        let groups = grouped.values.filter { group in group.pages.count >= 2 || explicit.contains(group.id) }
            .sorted { ($0.window, $0.name) < ($1.window, $1.name) }
        return Plan(app: inventory.app, groups: groups, unsupported: unsupported,
                    count: groups.reduce(0) { $0 + $1.pages.count })
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
                ["name": group.name, "color": group.color, "tabs": group.pages.map { page in
                    ["id": Int(page.tab.browserID ?? "") ?? -1, "windowId": page.tab.window, "index": page.tab.index - 1, "url": page.tab.url, "title": page.tab.title] as [String: Any]
                }] as [String: Any]
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
