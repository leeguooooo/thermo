import CloudDriveKit
import DownloadKit
import Foundation
import MediaToolsKit

/// Page settings. Nothing here is secret: trackers can carry passkeys, so they live in the Keychain.
struct YunXSettings: Codable, Equatable {
    enum ProxyMode: String, Codable, CaseIterable { case direct, system, manual }

    var saveDirectory = ""
    /// KB/s across every HTTP download; 0 means unlimited.
    var speedLimitKB = 0
    var p2pConnections = 32
    var p2pMaxRunning = 3
    var p2pDHT = true
    var proxyMode = ProxyMode.direct
    var proxyHost = ""
    var proxyPort = 0
    var trackers: [String] = []

    private enum CodingKeys: String, CodingKey {
        case saveDirectory, speedLimitKB, p2pConnections, p2pMaxRunning, p2pDHT, proxyMode, proxyHost, proxyPort
    }

    var speedLimitBytes: Int64 { Int64(max(speedLimitKB, 0)) * 1024 }

    var gopeed: GopeedRuntimeSettings {
        let proxy: GopeedProxy
        switch proxyMode {
        case .direct: proxy = .direct
        case .system: proxy = .system
        case .manual: proxy = .manual(host: proxyHost, port: proxyPort)
        }
        return GopeedRuntimeSettings(httpConnections: p2pConnections, proxy: proxy,
                                     trackers: trackers.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }, dhtEnabled: p2pDHT)
    }
}

struct YunXSettingsStore: @unchecked Sendable {
    private static let key = "yunx.download.settings"
    let defaults: UserDefaults
    let trackers: YunXSecretBackend

    init(defaults: UserDefaults = .standard, trackers: YunXSecretBackend = YunXKeychainBackend(account: "trackers")) {
        self.defaults = defaults
        self.trackers = trackers
    }

    func load() -> YunXSettings {
        var settings = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(YunXSettings.self, from: $0) } ?? YunXSettings()
        if let data = try? trackers.read(), let list = try? JSONDecoder().decode([String].self, from: data) { settings.trackers = list }
        return settings
    }

    func save(_ settings: YunXSettings, previous: YunXSettings) throws {
        var clean = settings
        // Gopeed writes its config to disk, and YunXSettings goes to a plist: no credentials in the host.
        if clean.proxyHost.contains("@") { clean.proxyHost = "" }
        defaults.set(try JSONEncoder().encode(clean), forKey: Self.key)
        if settings.trackers != previous.trackers { try trackers.write(try JSONEncoder().encode(settings.trackers)) }
    }
}

/// Lets the limiter's `@Sendable` closure read a value the main actor changes.
final class YunXLimitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64
    init(_ bytes: Int64) { self.bytes = bytes }
    var value: Int64 {
        get { lock.withLock { bytes } }
        set { lock.withLock { bytes = newValue } }
    }
}

/// Enough to pick a download up again after a restart: which file, never a link or header.
/// Holds share passcodes and file tokens, so it stays in the Keychain.
struct YunXJobRecord: Codable, Equatable, Identifiable, CustomStringConvertible, CustomReflectable {
    enum Kind: String, Codable { case share, drive, p2p }

    var id: UUID
    var kind: Kind
    /// May be relative, such as `Folder/Sub/file.mp4`.
    var name: String
    var saveDirectory: String
    /// DownloadKit's task, once it has one.
    var taskId: UUID?
    var platform = ""
    var shareId = ""
    var passcode = ""
    var fileId = ""
    var fileName = ""
    var fileSize: Int64 = 0
    var parentId = ""
    var fileToken = ""
    var p2pURL = ""
    var gopeedTask = ""
    var selectFiles: [Int] = []

    var file: DriveFile {
        DriveFile(id: fileId, name: fileName, size: fileSize, isDirectory: false, parentId: parentId, fileToken: fileToken)
    }

    var description: String { "YunXJobRecord(\(kind.rawValue), <redacted>)" }
    var customMirror: Mirror { Mirror(self, children: ["kind": kind]) }
}

/// The unfinished downloads, as one Keychain item.
final class YunXJobStore: @unchecked Sendable {
    private let backend: YunXSecretBackend
    private let lock = NSLock()

    init(backend: YunXSecretBackend = YunXKeychainBackend(account: "downloads")) { self.backend = backend }

    func load() -> [YunXJobRecord] {
        lock.withLock { read() }
    }

    func put(_ record: YunXJobRecord) {
        change { records in
            if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record } else { records.append(record) }
        }
    }

    func update(_ id: UUID, _ edit: (inout YunXJobRecord) -> Void) {
        change { records in
            if let index = records.firstIndex(where: { $0.id == id }) { edit(&records[index]) }
        }
    }

    func remove(_ id: UUID) {
        change { $0.removeAll { $0.id == id } }
    }

    private func read() -> [YunXJobRecord] {
        guard let data = try? backend.read() else { return [] }
        return (try? JSONDecoder().decode([YunXJobRecord].self, from: data)) ?? []
    }

    private func change(_ edit: (inout [YunXJobRecord]) -> Void) {
        lock.withLock {
            var records = read()
            let before = records
            edit(&records)
            if records != before, let data = try? JSONEncoder().encode(records) { try? backend.write(data) }
        }
    }
}

/// Walks a folder through whatever lists it. Drives can return loops, so ids are visited once.
enum YunXFolderWalker {
    static let maxFiles = 5000
    static let maxDepth = 32

    static func walk(_ root: DriveFile, list: (String) async throws -> [DriveFile]) async throws -> [(file: DriveFile, name: String)] {
        var found: [(file: DriveFile, name: String)] = []
        var seen: Set<String> = [root.id]
        var pending: [(id: String, prefix: String, depth: Int)] = [(root.id, root.name, 0)]
        while let folder = pending.popLast() {
            try Task.checkCancellation()
            for item in try await list(folder.id) where seen.insert(item.id).inserted {
                let name = "\(folder.prefix)/\(item.name)"
                if !item.isDirectory {
                    found.append((item, name))
                    if found.count > maxFiles { throw YunXLoginError.folderTooLarge }
                } else if folder.depth + 1 < maxDepth {
                    pending.append((item.id, name, folder.depth + 1))
                } else {
                    throw YunXLoginError.folderTooLarge
                }
            }
        }
        return found
    }
}

/// Jobs under one top-level folder of one save location. A lone file is a group of one.
struct YunXJobGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let isFolder: Bool
    var jobs: [YunXJob]

    var received: Int64 { jobs.reduce(0) { $0 + $1.received } }
    var total: Int64 { jobs.reduce(0) { $0 + ($1.total ?? 0) } }

    static func make(_ jobs: [YunXJob], globalRoot: String?) -> [YunXJobGroup] {
        var groups: [YunXJobGroup] = []
        for job in jobs {
            let item = DownloadGrouping.Item(fileName: job.relativeName, savePath: job.savedPath, saveDirectory: job.saveDirectory)
            let key = DownloadGrouping.groupKey(item, globalRoot: globalRoot)
            let isFolder = job.relativeName.contains("/")
            let id = isFolder ? "\(key.root)\u{0}\(key.folder)" : job.id.uuidString
            if let index = groups.firstIndex(where: { $0.id == id }) {
                groups[index].jobs.append(job)
            } else {
                groups.append(YunXJobGroup(id: id, title: key.folder, isFolder: isFolder, jobs: [job]))
            }
        }
        return groups
    }
}
