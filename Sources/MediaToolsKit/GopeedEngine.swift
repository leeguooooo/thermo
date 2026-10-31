import Darwin
import Foundation

public enum GopeedError: Error, Equatable, Sendable {
    case notInstalled
    case notRunning
    case alreadyStarting
    case startFailed(exitCode: Int32?)
    case api(String)
    case invalidResponse
    case missingTaskID
}

public enum GopeedProxy: Sendable, Equatable {
    case direct
    case system
    case manual(host: String, port: Int)

    /// Gopeed's `proxy` config. Gopeed keeps its config on disk, so a host carrying credentials is dropped.
    var json: [String: Any] {
        switch self {
        case .direct:
            return ["enable": false]
        case .system:
            return ["enable": true, "system": true]
        case let .manual(host, port):
            let host = host.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty, !host.contains("@"), (1...65535).contains(port) else { return ["enable": false] }
            return ["enable": true, "system": false, "scheme": "http", "host": "\(host):\(port)"]
        }
    }
}

/// App settings the engine needs; YunX read these from SettingsRepository.
public struct GopeedRuntimeSettings: Sendable, Equatable {
    public var httpConnections: Int
    public var proxy: GopeedProxy
    public var trackers: [String]
    public var dhtEnabled: Bool

    public init(httpConnections: Int = 32, proxy: GopeedProxy = .direct, trackers: [String] = [], dhtEnabled: Bool = true) {
        self.httpConnections = httpConnections
        self.proxy = proxy
        self.trackers = trackers
        self.dhtEnabled = dhtEnabled
    }
}

public struct GopeedTaskView: Sendable, Equatable {
    public var id: String
    public var status: String
    public var downloaded: Int64
    public var total: Int64
    public var speed: Int64
}

public struct GopeedTaskDetail: Sendable, Equatable {
    public var name: String
    public var fileCount: Int
    /// True when the task lands as a directory rather than one file.
    public var folder: Bool
}

/// One entry of a resolved torrent. Its index in `GopeedResolved.files` is what `selectFiles` takes.
public struct GopeedResolvedFile: Sendable, Equatable {
    public var name: String
    public var path: String
    public var size: Int64

    public var displayPath: String { path.isEmpty ? name : "\(path)/\(name)" }
}

public struct GopeedResolved: Sendable, Equatable {
    public var name: String
    public var files: [GopeedResolvedFile]
}

public struct GopeedPeerInfo: Sendable, Equatable {
    /// -1 means the engine did not report it.
    public var seeds: Int
    public var peers: Int
    public var total: Int
}

public protocol GopeedProcess: AnyObject, Sendable {
    var pid: Int32 { get }
    var isRunning: Bool { get }
    var exitCode: Int32? { get }
    func terminate()
    func forceKill()
}

public protocol GopeedLauncher: Sendable {
    func launch(executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL) throws -> GopeedProcess
    func executablePath(pid: Int32) -> String?
    func forceKill(pid: Int32)
    func freePort() throws -> Int
}

/// The Gopeed web build as a child process, driven over its REST API on 127.0.0.1.
///
/// The child's output is discarded rather than logged to a file as YunX does, because a kernel
/// we do not control could print a signed URL. Applications must call `stop()` on termination;
/// an orphan left by a crash is cleaned up by the next `start`.
///
/// Each start gets a fresh API token, because the REST API allows any browser origin and any
/// local process could otherwise read task URLs and headers. Gopeed answers 401 to a request
/// without `X-Api-Token`. The token reaches it through `GOPEED_APITOKEN`, the same field as `-T`
/// (gopeed v1.9.3 `cmd/web/flags.go`), so it never shows in the process's argv.
public actor GopeedEngine {
    public enum State: Sendable, Equatable { case notInstalled, installed, running }

    public enum TaskStatus {
        public static let ready = "ready"
        public static let running = "running"
        public static let wait = "wait"
        public static let pause = "pause"
        public static let error = "error"
        public static let done = "done"
    }

    static let apiTokenVariable = "GOPEED_APITOKEN"
    static let apiTokenHeader = "X-Api-Token"

    /// Without a UA, CDNs throttle pasted links.
    private static let defaultUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36"

    public private(set) var state: State = .notInstalled
    public private(set) var port = 0
    public private(set) var lastError: String?

    private let root: MediaToolsRoot
    private let transport: MediaHTTPTransport
    private let launcher: GopeedLauncher
    private let runner: ToolRunner
    private let readyTimeout: TimeInterval
    private let stopTimeout: TimeInterval
    private var process: GopeedProcess?
    /// Memory only, and replaced on every start.
    private var apiToken = ""

    public init(root: MediaToolsRoot, transport: MediaHTTPTransport = URLSessionMediaTransport.loopback, launcher: GopeedLauncher = SystemGopeedLauncher(), runner: ToolRunner = ProcessToolRunner()) {
        self.init(root: root, transport: transport, launcher: launcher, runner: runner, readyTimeout: 20, stopTimeout: 3)
    }

    init(root: MediaToolsRoot, transport: MediaHTTPTransport, launcher: GopeedLauncher, runner: ToolRunner, readyTimeout: TimeInterval, stopTimeout: TimeInterval) {
        self.root = root
        self.transport = transport
        self.launcher = launcher
        self.runner = runner
        self.readyTimeout = readyTimeout
        self.stopTimeout = stopTimeout
    }

    // MARK: Kernel files

    public var isInstalled: Bool { (try? root.validatedExecutable(root.gopeedExecutable)) != nil }

    public func syncInstalledState() {
        guard state != .running else { return }
        state = isInstalled ? .installed : .notInstalled
    }

    /// Accepts the official zip or a bare kernel binary, only when it hashes to `expectedSHA256`.
    public func installFromArchive(_ archive: URL, expectedSHA256: String) async throws {
        try ToolInstaller.verify(archive, expected: expectedSHA256)
        if state == .running { await stop() }
        let target = root.gopeedExecutable
        if archive.pathExtension.lowercased() == "zip" {
            try await ToolInstaller.install(
                archive: archive, expectedSHA256: expectedSHA256, entryName: "gopeed", to: target, root: root, runner: runner)
        } else {
            try ToolInstaller.installBinary(from: archive, expectedSHA256: expectedSHA256, to: target)
        }
        lastError = nil
        state = .installed
    }

    /// Keeps storage so unfinished task metadata survives a reinstall.
    public func uninstall() async {
        if state == .running { await stop() }
        try? FileManager.default.removeItem(at: root.gopeedExecutable)
        state = .notInstalled
    }

    // MARK: Lifecycle

    /// Idempotent. Only `-A/-P/-d` are passed: an unknown flag makes Gopeed print usage and exit.
    @discardableResult
    public func start() async throws -> Int {
        if state == .running { return port }
        guard process == nil else { throw GopeedError.alreadyStarting }
        let executable: URL
        do {
            executable = try root.validatedExecutable(root.gopeedExecutable)
        } catch MediaToolsError.executableOutsideRoot {
            throw MediaToolsError.executableOutsideRoot
        } catch {
            throw GopeedError.notInstalled
        }
        lastError = nil
        killStaleProcess(executable)

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root.gopeedDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Gopeed's own store keeps task URLs and headers, so nobody else may read it.
        try fileManager.createDirectory(at: root.gopeedStorage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.gopeedStorage.path)

        let localPort = try launcher.freePort()
        let arguments = ["-A", "127.0.0.1", "-P", String(localPort), "-d", root.gopeedStorage.path]
        let token = Self.makeAPIToken()
        let child = try launcher.launch(
            executable: executable, arguments: arguments, environment: [Self.apiTokenVariable: token], workingDirectory: root.gopeedDir)
        process = child
        port = localPort
        apiToken = token

        guard await awaitReady(child) else {
            let exitCode = child.isRunning ? nil : child.exitCode
            child.forceKill()
            if process === child {
                process = nil
                port = 0
                apiToken = ""
            }
            lastError = exitCode.map { "Gopeed exited with code \($0)" } ?? "Gopeed did not answer in time"
            throw GopeedError.startFailed(exitCode: exitCode)
        }
        try? String(child.pid).write(to: root.gopeedPIDFile, atomically: true, encoding: .utf8)
        state = .running
        return localPort
    }

    public func stop() async {
        let child = process
        process = nil
        port = 0
        apiToken = ""
        try? FileManager.default.removeItem(at: root.gopeedPIDFile)
        if let child {
            child.terminate()
            let deadline = Date().addingTimeInterval(stopTimeout)
            while child.isRunning, Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if child.isRunning { child.forceKill() }
        }
        if state == .running { state = .installed }
    }

    @discardableResult
    public func restart() async throws -> Int {
        await stop()
        return try await start()
    }

    /// An orphan from a killed app still holds the bolt lock. Matched by path so a Gopeed the user runs is left alone.
    private static func makeAPIToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }

    private func killStaleProcess(_ executable: URL) {
        guard let text = try? String(contentsOf: root.gopeedPIDFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        try? FileManager.default.removeItem(at: root.gopeedPIDFile)
        guard pid > 1, pid != process?.pid, let path = launcher.executablePath(pid: pid),
              URL(fileURLWithPath: path).resolvingSymlinksInPath().path == executable.resolvingSymlinksInPath().path else { return }
        launcher.forceKill(pid: pid)
    }

    private func awaitReady(_ child: GopeedProcess) async -> Bool {
        let deadline = Date().addingTimeInterval(readyTimeout)
        while Date() < deadline {
            guard child.isRunning, process === child else { return false }
            if (try? await getObject("/api/v1/info")) != nil { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }

    // MARK: Tasks

    public func version() async -> String? {
        guard let version = (try? await getObject("/api/v1/info"))?["version"] as? String, !version.isEmpty else { return nil }
        return version
    }

    /// `url`, `headers` and `trackers` may hold secrets: they go to the engine and nowhere else.
    public func createTask(
        url: String, saveDir: String, fileName: String, headers: [String: String] = [:], connections: Int = 0,
        label: String = "", trackers: [String] = [], selectFiles: [Int] = []
    ) async throws -> String {
        var request: [String: Any] = ["url": url]
        var extra: [String: Any] = [:]
        if !headers.isEmpty { extra["header"] = headers }
        if !trackers.isEmpty { extra["trackers"] = trackers }
        if !extra.isEmpty { request["extra"] = extra }
        if !label.isEmpty { request["labels"] = ["thermoTaskId": label] }
        var options: [String: Any] = ["path": saveDir]
        if !fileName.isEmpty { options["name"] = fileName }
        if connections > 0 { options["extra"] = ["connections": connections] }
        // Sent with `req`, not a resolve `rid`: gopeed v1.9.3's `Create(rid)` ignores `opts`.
        if !selectFiles.isEmpty { options["selectFiles"] = selectFiles }
        let body = try JSONSerialization.data(withJSONObject: ["req": request, "opts": options])
        // Unlike the query endpoints, `data` here is the task id string.
        let envelope = try await send("POST", "/api/v1/tasks", body: body)
        guard let id = (envelope["data"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            throw GopeedError.missingTaskID
        }
        return id
    }

    /// Lists what a magnet or torrent holds without starting it. A magnet has to find peers first.
    public func resolve(url: String) async throws -> GopeedResolved {
        let body = try JSONSerialization.data(withJSONObject: ["req": ["url": url]])
        let envelope = try await send("POST", "/api/v1/resolve", body: body)
        guard let resource = (envelope["data"] as? [String: Any])?["res"] as? [String: Any] else { throw GopeedError.invalidResponse }
        let files = (resource["files"] as? [[String: Any]] ?? []).map {
            GopeedResolvedFile(name: $0["name"] as? String ?? "", path: $0["path"] as? String ?? "", size: Self.int64($0["size"]))
        }
        return GopeedResolved(name: resource["name"] as? String ?? "", files: files)
    }

    /// Reads the task itself: `/tasks/{id}/status` does not exist on the server.
    public func taskStatus(_ id: String) async throws -> GopeedTaskView {
        let data = try await getObject(Self.taskPath(id))
        let progress = data["progress"] as? [String: Any]
        let resource = (data["meta"] as? [String: Any])?["res"] as? [String: Any]
        return GopeedTaskView(
            id: (data["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id,
            status: data["status"] as? String ?? "",
            downloaded: Self.int64(progress?["downloaded"]), total: Self.int64(resource?["size"]), speed: Self.int64(progress?["speed"]))
    }

    /// YunX falls back to the whole task JSON here. That JSON holds the URL and headers, so this returns only the error.
    public func taskError(_ id: String) async -> String? {
        guard let data = try? await getObject(Self.taskPath(id)) else { return nil }
        for key in ["error", "err"] {
            if let text = (data[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return Redaction.stripURLQueries(text)
            }
        }
        return nil
    }

    /// Live connection count. YunX reads top-level `connections`, but its own notes put HTTP stats under `snapshot`; both are accepted.
    public func taskConnections(_ id: String) async -> Int? {
        guard let data = try? await getObject(Self.taskPath(id) + "/stats") else { return nil }
        let list = data["connections"] as? [Any] ?? (data["snapshot"] as? [String: Any])?["connections"] as? [Any]
        return list?.count
    }

    public func taskPeerInfo(_ id: String) async -> GopeedPeerInfo? {
        guard let data = try? await getObject(Self.taskPath(id) + "/stats") else { return nil }
        let runtime = data["runtime"] as? [String: Any] ?? data
        func value(_ key: String) -> Int { (runtime[key] as? NSNumber)?.intValue ?? -1 }
        let info = GopeedPeerInfo(seeds: value("connectedSeeders"), peers: value("activePeers"), total: value("totalPeers"))
        return info.seeds < 0 && info.peers < 0 && info.total < 0 ? nil : info
    }

    public func hasActiveTasks() async -> Bool {
        guard let tasks = try? await getList("/api/v1/tasks") else { return false }
        return tasks.contains { [TaskStatus.ready, TaskStatus.running, TaskStatus.wait].contains($0["status"] as? String ?? "") }
    }

    public func pauseTask(_ id: String) async throws {
        _ = try await send("PUT", Self.taskPath(id) + "/pause")
    }

    public func continueTask(_ id: String) async throws {
        _ = try await send("PUT", Self.taskPath(id) + "/continue")
    }

    /// Also how a finished task's URL and headers leave Gopeed's store, so callers should do this once a task is done.
    public func deleteTask(_ id: String) async throws {
        _ = try await send("DELETE", Self.taskPath(id))
    }

    public func taskDetail(_ id: String) async throws -> GopeedTaskDetail {
        let data = try await getObject(Self.taskPath(id))
        let resource = (data["meta"] as? [String: Any])?["res"] as? [String: Any]
        let files = resource?["files"] as? [[String: Any]] ?? []
        let hasSubPath = files.contains { !($0["path"] as? String ?? "").isEmpty }
        let resourceName = resource?["name"] as? String ?? ""
        return GopeedTaskDetail(
            name: resourceName.isEmpty ? data["name"] as? String ?? "" : resourceName,
            fileCount: files.count, folder: hasSubPath || files.count > 1)
    }

    // MARK: Config

    /// Applies what the app owns over REST, because start-up config only counts on an empty store.
    /// Everything else in the fetched config goes back unchanged, since `PUT` replaces the whole object.
    /// Returns nil when the engine is not running.
    @discardableResult
    public func applyRuntimeConfig(maxRunning: Int, settings: GopeedRuntimeSettings, wakeQueued: Bool = true) async throws -> Int? {
        guard state == .running else { return nil }
        let value = max(maxRunning, 1)
        var config = try await getObject("/api/v1/config")
        config["maxRunning"] = value
        var protocols = config["protocolConfig"] as? [String: Any] ?? [:]

        var bt = protocols["bt"] as? [String: Any] ?? [:]
        bt["seedKeep"] = false
        bt["seedRatio"] = 0
        // seedTime 0 with ratio 0 means "seed forever"; 1 second is what actually stops.
        bt["seedTime"] = 1
        bt["customTrackers"] = settings.trackers
        bt["disableDht"] = !settings.dhtEnabled
        protocols["bt"] = bt

        var http = protocols["http"] as? [String: Any] ?? [:]
        http["connections"] = min(max(settings.httpConnections, 1), 512)
        if (http["userAgent"] as? String ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            http["userAgent"] = Self.defaultUserAgent
        }
        protocols["http"] = http
        config["protocolConfig"] = protocols
        config["proxy"] = settings.proxy.json

        _ = try await send("PUT", "/api/v1/config", body: try JSONSerialization.data(withJSONObject: config))
        if wakeQueued { await wakeQueuedTasks(maxRunning: value) }
        return value
    }

    /// The engine only backfills when a task ends, so raising the limit leaves the queue idle. `continue`
    /// on a full engine pauses a running task, so this wakes strictly as many as there are free slots.
    private func wakeQueuedTasks(maxRunning: Int) async {
        guard let tasks = try? await getList("/api/v1/tasks") else { return }
        let running = tasks.filter { $0["status"] as? String == TaskStatus.running }.count
        let waiting = tasks.filter { $0["status"] as? String == TaskStatus.wait }.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
        for id in waiting.prefix(max(maxRunning - running, 0)) {
            try? await continueTask(id)
        }
    }

    // MARK: HTTP

    private static func taskPath(_ id: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.")
        return "/api/v1/tasks/" + (id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id)
    }

    private static func int64(_ value: Any?) -> Int64 { (value as? NSNumber)?.int64Value ?? 0 }

    private func getObject(_ path: String) async throws -> [String: Any] {
        try await send("GET", path)["data"] as? [String: Any] ?? [:]
    }

    private func getList(_ path: String) async throws -> [[String: Any]] {
        try await send("GET", path)["data"] as? [[String: Any]] ?? []
    }

    /// Parses `{code,msg,data}`. Response text never reaches an error unfiltered, since it can quote task URLs.
    private func send(_ method: String, _ path: String, body: Data? = nil) async throws -> [String: Any] {
        guard port > 0, let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { throw GopeedError.notRunning }
        var payload = body
        if payload == nil, method == "POST" || method == "PUT" { payload = Data("{}".utf8) }
        var headers = [Self.apiTokenHeader: apiToken]
        if payload != nil { headers["Content-Type"] = "application/json; charset=utf-8" }
        let request = MediaRequest(method: method, url: url, headers: headers, body: payload)
        let response = try await transport.send(request)
        let data = try await response.collect(limit: 32 << 20)
        if data.isEmpty {
            guard response.isSuccess else { throw GopeedError.api("HTTP \(response.statusCode)") }
            return [:]
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GopeedError.invalidResponse }
        let code = (json["code"] as? NSNumber)?.intValue ?? 0
        guard code == 0 else {
            let message = (json["msg"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "code \(code)"
            throw GopeedError.api(Redaction.stripURLQueries(message))
        }
        return json
    }
}

public struct SystemGopeedLauncher: GopeedLauncher {
    public init() {}

    public func launch(executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL) throws -> GopeedProcess {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.currentDirectoryURL = workingDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return SystemGopeedProcess(process)
    }

    public func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    public func forceKill(pid: Int32) {
        kill(pid, SIGKILL)
    }

    /// Bound and released, so a small race with Gopeed's own bind remains; `restart` recovers.
    public func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(fd, generic, length) == 0 && getsockname(fd, generic, &length) == 0
            }
        }
        guard bound else { throw POSIXError(.EADDRNOTAVAIL) }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

private final class SystemGopeedProcess: GopeedProcess, @unchecked Sendable {
    private let process: Process

    init(_ process: Process) {
        self.process = process
    }

    var pid: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }
    var exitCode: Int32? { process.isRunning ? nil : process.terminationStatus }
    func terminate() { process.terminate() }
    func forceKill() { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
}
