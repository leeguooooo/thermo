import Foundation

/// Export only input metadata useful for inspection/control; hardware UIDs remain internal.
public struct AudioInputReport: Codable, Sendable {
    public struct Client: Codable, Sendable {
        public var pid: Int32
        public var processStarted: Date?
        public var name: String
        public var appKey: String
        public var bundleID: String?
        public var devices: [String]
    }
    public struct MutedApp: Codable, Sendable {
        public var key: String
        public var name: String
    }
    public let schemaVersion: Int
    public let source: String
    public let scope: String
    public let recordsAudio: Bool
    public let state: String
    public let sampled: Date?
    public let available: Bool?
    public let complete: Bool?
    public let fresh: Bool?
    public let enabled: Bool?
    public let reading: Bool?
    public let eventCoverage: String?
    public let notificationAccess: String?
    public let notificationIssue: String?
    public let notificationIssueTruncated: Bool
    public let totalClients: Int
    public private(set) var clients: [Client]
    public let totalMutedApps: Int
    public private(set) var mutedApps: [MutedApp]
    public let totalIssues: Int
    public private(set) var issues: [String]
    public private(set) var outputTruncated: Bool

    public init(observation: AudioInputObservation?, source: String, enabled: Bool? = nil,
                reading: Bool? = nil, eventCoverage: String? = nil, notificationAccess: String? = nil,
                muted: [String: String] = [:], notificationIssue: String? = nil, limit: Int = 64, byteBudget: Int? = nil, now: Date = Date()) {
        self.schemaVersion = 1; self.scope = "currentUser"; self.recordsAudio = false
        self.source = source; self.enabled = enabled; self.reading = reading
        self.eventCoverage = eventCoverage; self.notificationAccess = notificationAccess
        self.notificationIssue = notificationIssue.map { String(decoding: $0.utf8.prefix(1024), as: UTF8.self) }
        self.notificationIssueTruncated = (notificationIssue?.utf8.count ?? 0) > 1024
        self.sampled = observation?.sampled.timeIntervalSinceReferenceDate.isFinite == true ? observation?.sampled : nil
        self.available = observation?.available; self.complete = observation?.complete
        self.fresh = observation.map { (0...15).contains(now.timeIntervalSince($0.sampled)) }
        if let observation {
            state = !observation.complete ? "unknown" : fresh == false ? "stale" : observation.clients.isEmpty ? "idle" : "active"
        } else { state = enabled == true ? "checking" : "notCollected" }
        let count = max(0, min(4096, limit))
        totalClients = observation?.clients.count ?? 0
        clients = Array((observation?.clients ?? []).prefix(count)).map {
            Client(pid: $0.process.pid, processStarted: $0.process.started.timeIntervalSinceReferenceDate.isFinite ? $0.process.started : nil, name: $0.name,
                   appKey: $0.muteKey, bundleID: $0.bundleID, devices: $0.devices.map(\.name))
        }
        totalMutedApps = muted.count
        mutedApps = muted.keys.sorted().prefix(count).map { MutedApp(key: $0, name: muted[$0]!) }
        totalIssues = observation?.issues.count ?? 0
        issues = observation?.issues ?? []
        outputTruncated = clients.count < totalClients || mutedApps.count < totalMutedApps || notificationIssueTruncated
        // App-control frames are 64 KiB. Reserve at least half for the envelope and future fields.
        if let byteBudget {
            let budget = max(2048, byteBudget)
            while ((try? JSONEncoder().encode(self).count) ?? Int.max) > budget {
                if !mutedApps.isEmpty { mutedApps.removeLast() }
                else if !clients.isEmpty { clients.removeLast() }
                else if !issues.isEmpty { issues.removeLast() }
                else { break }
                outputTruncated = true
            }
        }
    }
}
