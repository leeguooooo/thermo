import AgentCore
import Darwin
import Foundation

/// Size of a file tree: symlinks are not followed, it stays on one volume, hard links count once.
public struct TreeSize: Sendable {
    /// What removing it would free: each file's private (unshared) blocks. On APFS, clones and
    /// snapshot-shared data make this smaller — sometimes far smaller — than `allocated`.
    public var bytes: Int64 = 0
    /// Space the files take up as `du` counts it, shared blocks included.
    public var allocated: Int64 = 0
    public var files: Int = 0
    public var newest: Date?
    public var denied = false
    public var incomplete = false

    public static func + (a: TreeSize, b: TreeSize) -> TreeSize {
        var r = a
        r.bytes += b.bytes; r.allocated += b.allocated; r.files += b.files; r.denied = a.denied || b.denied; r.incomplete = a.incomplete || b.incomplete
        if let n = b.newest, n > (r.newest ?? .distantPast) { r.newest = n }
        return r
    }
}

/// Used space, not a promise of how much deletion frees (APFS clones may share blocks).
public struct DiskFootprint: Sendable {
    public let allocated: Int64
    public let files: Int
    public let newest: Date?
    public let denied: Bool
    public var incomplete = false
}

public enum FS {
    static let fm = FileManager.default

    public static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    public static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// Ages count status changes (ctime) as well as content changes, so something moved, renamed or
    /// unpacked recently is not taken for untouched. Tests that backdate files with `utimes` turn it off.
    nonisolated(unsafe) static var countsStatusChanges = true

    public static func mtime(_ path: String) -> Date? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
    }

    /// Directory entries with their type from `readdir` (no stat per entry). Symlinks are never directories.
    public static func entries(_ path: String) -> [(name: String, isDir: Bool)]? {
        guard let d = opendir(path) else { return nil }
        defer { closedir(d) }
        var out: [(String, Bool)] = []
        while let e = readdir(d) {
            let name = withUnsafeBytes(of: e.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(e.pointee.d_namlen)), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            out.append((name, e.pointee.d_type == DT_DIR))
        }
        return out
    }

    public static func children(_ path: String) -> [String] {
        (try? fm.contentsOfDirectory(atPath: path))?.map { path + "/" + $0 } ?? []
    }

    /// Sizes a path. `trackNewest` stats modification times too (slightly slower).
    /// Stops early (partial size) when the running scan is cancelled.
    public static func size(_ path: String, trackNewest: Bool = false, cancellation: ScanCancellation? = nil) -> TreeSize {
        measure(path, trackNewest: trackNewest, cancellation: cancellation, privateSizes: true)
    }

    /// Application inventory reports allocated usage, not reclaimable private blocks.
    /// Keep completeness flags without performing per-file APFS ownership queries.
    static func allocatedSize(_ path: String, cancellation: ScanCancellation? = nil) -> TreeSize {
        var result = measure(path, trackNewest: false, cancellation: cancellation, privateSizes: false)
        result.bytes = result.allocated
        return result
    }

    /// Fast discovery: batched allocation metadata only; no expensive APFS private-block queries.
    public static func footprint(_ path: String, cancellation: ScanCancellation? = nil) -> DiskFootprint {
        let result = measure(path, trackNewest: false, cancellation: cancellation, privateSizes: false)
        return DiskFootprint(allocated: result.allocated, files: result.files, newest: result.newest, denied: result.denied, incomplete: result.incomplete)
    }

    /// Bounded allocation discovery, never used as a deletion's before/after measurement.
    public static func discoverySize(_ path: String, maxEntries: Int = 20_000) -> TreeSize {
        var result = measure(path, trackNewest: true, cancellation: nil, privateSizes: false, maxEntries: maxEntries)
        result.bytes = result.allocated
        return result
    }

    private static func measure(_ path: String, trackNewest: Bool, cancellation: ScanCancellation?, privateSizes: Bool, maxEntries: Int? = nil) -> TreeSize {
        let cancellation = cancellation ?? ScanCancellation.current
        if cancellation?.isCancelled == true { var result = TreeSize(); result.incomplete = true; return result }
        var r = TreeSize()
        var st = stat()
        guard lstat(path, &st) == 0 else {
            r.incomplete = true
            if errno == EACCES || errno == EPERM { r.denied = true }
            return r
        }
        if (st.st_mode & S_IFMT) != S_IFDIR {
            let blocks = Int64(st.st_blocks) * 512
            let sizes = privateSizes && (st.st_mode & S_IFMT) == S_IFREG ? BulkWalk.fileSize(path) : nil
            r.allocated = sizes?.allocated ?? blocks
            r.bytes = sizes?.privateSize ?? blocks
            r.files = 1
            r.newest = Date(timeIntervalSince1970: TimeInterval(max(st.st_mtimespec.tv_sec, countsStatusChanges ? st.st_ctimespec.tv_sec : 0)))
            return r
        }
        // Batched attributes with private sizes; fts below is the fallback for file systems
        // without getattrlistbulk.
        if let bulk = BulkWalk.size(path, trackNewest: trackNewest, device: st.st_dev, cancellation: cancellation, privateSizes: privateSizes, maxEntries: maxEntries) { return bulk }
        var seenInodes = Set<UInt64>()
        let opts = FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV
        var newest: Int = 0
        path.withCString { cpath in
            var argv: [UnsafeMutablePointer<CChar>?] = [strdup(cpath), nil]
            defer { free(argv[0]) }
            guard let fts = fts_open(&argv, opts, nil) else { r.incomplete = true; return }
            defer { fts_close(fts) }
            var visited = 0
            while true {
                errno = 0
                guard let ent = fts_read(fts) else { if errno != 0 { r.incomplete = true }; break }
                visited += 1
                if cancellation?.isCancelled == true || maxEntries.map({ visited > $0 }) == true { r.incomplete = true; break }
                let info = Int32(ent.pointee.fts_info)
                switch info {
                case FTS_DNR, FTS_ERR, FTS_NS:
                    r.incomplete = true
                    if ent.pointee.fts_errno == EACCES || ent.pointee.fts_errno == EPERM { r.denied = true }
                case FTS_DP:
                    continue
                default:
                    guard let sp = ent.pointee.fts_statp else { r.incomplete = true; continue }
                    let s = sp.pointee
                    if (s.st_mode & S_IFMT) != S_IFDIR {
                        if s.st_nlink > 1 && !seenInodes.insert(UInt64(s.st_ino)).inserted { continue }
                        r.files += 1
                    }
                    r.bytes += Int64(s.st_blocks) * 512
                    r.allocated += Int64(s.st_blocks) * 512
                    if trackNewest { newest = max(newest, s.st_mtimespec.tv_sec, FS.countsStatusChanges ? s.st_ctimespec.tv_sec : 0) }
                }
            }
        }
        if trackNewest, newest > 0 { r.newest = Date(timeIntervalSince1970: TimeInterval(newest)) }
        return r
    }

    public static func size(_ paths: [String], trackNewest: Bool = false) -> TreeSize {
        paths.reduce(TreeSize()) { $0 + size($1, trackNewest: trackNewest) }
    }

    /// Reads up to `limit` bytes from the start of a file.
    public static func head(_ path: String, limit: Int = 64 * 1024) -> Data? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        return try? h.read(upToCount: limit)
    }

    public static func expand(_ path: String, home: String = NSHomeDirectory()) -> String {
        path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst() : path
    }

    /// `/Users/leo/x` → `~/x` for display.
    public static func tilde(_ path: String, home: String = NSHomeDirectory()) -> String {
        path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - Removal

public struct CleanResult: Codable, Sendable {
    public var id: String
    public var removed: [String] = []
    public var failed: [String: String] = [:]
    /// Estimated private bytes of the removed files, not the measured volume change.
    public var bytes: Int64 = 0
    public var spaceObservation: DiskSpaceObservation?
    public var trashed: Bool
    public var partialRemoved: [String]? = nil
    public var bytesIncomplete: Bool? = nil
    public var outcome: String? = nil
    public var trashBatchID: String? = nil
    public var trashedAllocatedBytes: Int64? = nil
    /// Paths skipped because the user's whitelist keeps them (reason "whitelisted").
    public var whitelisted: [String]? = nil

    public init(id: String, trashed: Bool) { self.id = id; self.trashed = trashed }
}

public enum RemovalMode: String, Sendable {
    /// Caches go away for good, user data goes to the Trash.
    case auto
    case trash
    case permanent

    public func trashes(_ safety: Safety) -> Bool {
        switch self {
        case .auto: return safety != .safe
        case .trash: return true
        case .permanent: return false
        }
    }
}

public enum Cleaner {
    public static var logURL: URL { logURL(home: NSHomeDirectory()) }

    static func logURL(home: String) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Logs/Thermo/clean.log")
    }

    /// Removes the item's paths. Every path is re-checked against `Guard`; nothing outside
    /// `item.paths` is touched.
    /// `scannedAt`: paths modified after this moment changed since the user saw the scan and are skipped.
    public static func clean(_ item: CleanItem, mode: RemovalMode = .auto, guard g: Guard = Guard(),
                             scannedAt: Date? = nil, processTable: ProcessTable? = nil, batchID: String? = nil) -> CleanResult {
        clean(item, mode: mode, guard: g, scannedAt: scannedAt, processTable: processTable, batchID: batchID, operations: .live)
    }

    static func clean(_ item: CleanItem, mode: RemovalMode, guard g: Guard, scannedAt: Date?,
                      processTable: ProcessTable?, batchID: String?, operations: RemovalOperations) -> CleanResult {
        let before = DiskSpaceSnapshot.measure(path: g.home)
        var result = perform(item, mode: mode, guard: g, scannedAt: scannedAt, processTable: processTable, batchID: batchID ?? UUID().uuidString, operations: operations)
        if let batch = result.trashBatchID {
            do { try TrashBatches.synchronize(batch, home: g.home) }
            catch { result.failed["batch/" + batch] = error.localizedDescription }
        }
        result.outcome = result.failed.isEmpty ? "success" : (result.removed.isEmpty && result.partialRemoved?.isEmpty != false ? "failed" : "partial")
        if !result.removed.isEmpty || result.partialRemoved?.isEmpty == false {
            ScanReportCache.invalidate(home: g.home)
            SpaceOverview.invalidate(home: g.home)
        }
        result.spaceObservation = DiskSpaceObservation(before: before, after: DiskSpaceSnapshot.measure(path: g.home))
        log(result, item: item, home: g.home)
        return result
    }

    /// A live check, also usable while preparing a review. A cached scan is not proof that
    /// its owning app, build tool, or executable is still idle.
    public static func refusal(_ item: CleanItem, mode: RemovalMode, processes: ProcessTable) -> String? {
        refusal(item, mode: mode, processes: processes, locations: item.paths.map(Guard.deletionLocation))
    }

    /// `locations`: the item's paths as removal would resolve them, computed once per item.
    static func refusal(_ item: CleanItem, mode: RemovalMode, processes: ProcessTable, locations: [String]) -> String? {
        let rule = Rules.paths.first(where: { $0.id == item.id })
        if let blocked = item.blocked {
            // Only the rule's known running-app block may be cleared by this live check.
            let appMessages = (rule?.apps ?? []).map { tr("quit %1$@ first", $0) }
            let projectMessages = [.projects, .agentWorktrees].contains(item.category) ? [tr("an agent is running in it"), tr("a build tool is running in this project"), tr("a running executable uses this location")] : []
            if !appMessages.contains(blocked) && !projectMessages.contains(blocked) { return blocked }
        }
        if mode == .trash, !(item.commands ?? []).isEmpty {
            return tr("Tool-managed removal is permanent and cannot use the Trash")
        }
        if let rule, let app = processes.running(rule.apps) {
            return tr("quit %1$@ first", app)
        }
        if ToolCleanup.isBrowserOldVersion(item), let app = processes.running([String(item.id.dropFirst(ToolCleanup.oldVersionPrefix.count))]) {
            return tr("quit %1$@ first", app)
        }
        if item.category == .agentWorktrees {
            for path in item.paths {
                do { _ = try WorktreeCleanup.registration(path, processes: processes) }
                catch { return String(describing: error) }
            }
        }
        if item.category == .projects, processes.entries.contains(where: { process in
            process.argv.contains { argument in locations.contains { argument == $0 || argument.hasPrefix($0 + "/") || argument.contains("=" + $0 + "/") || argument.hasSuffix("=" + $0) } }
        }) { return tr("a build tool is running in this project") }
        if let group = item.group, item.category == .projects {
            let dir = URL(fileURLWithPath: group).resolvingSymlinksInPath().path
            let related: (String) -> Bool = { rawCWD in
                let cwd = URL(fileURLWithPath: rawCWD).resolvingSymlinksInPath().path
                return cwd == dir || cwd.hasPrefix(dir + "/") ||
                    (dir.hasPrefix(cwd + "/") && ProjectSignals.isRepoRoot(cwd, containing: dir))
            }
            if processes.agentDirectories().contains(where: related) { return tr("an agent is running in it") }
            let builders = ["swift", "swift-build", "swift-frontend", "cargo", "rustc", "xcodebuild", "clang", "clang++",
                            "cmake", "ninja", "make", "gradle", "mvn", "flutter", "dart", "npm", "pnpm", "yarn",
                            "node", "java", "python", "python3", "dotnet", "zig", "go"]
            if processes.entries.contains(where: { builders.contains($0.name) && $0.cwd.map(related) == true }) {
                return tr("a build tool is running in this project")
            }
        }
        // Resolved once per item: per process it was paths × processes symlink lookups (1,600 sessions took minutes).
        if processes.entries.contains(where: { process in
            guard let exe = process.executable else { return false }
            return locations.contains { exe == $0 || exe.hasPrefix($0 + "/") }
        }) { return tr("a running executable uses this location") }
        return nil
    }

    static func perform(_ item: CleanItem, mode: RemovalMode, guard g: Guard, scannedAt: Date?, processTable: ProcessTable?,
                        batchID: String, operations: RemovalOperations) -> CleanResult {
        let trash = mode.trashes(item.safety) && !item.paths.isEmpty
        var result = CleanResult(id: item.id, trashed: trash)
        let whitelist: Whitelist
        do { whitelist = try Whitelist.loadForRemoval(home: g.home) } catch {
            result.failed[item.id] = Whitelist.unreadable(error)
            return result
        }
        if let why = refusal(item, mode: mode, processes: processTable ?? ProcessTable.current(.init(cpu: false))) {
            result.failed[item.id] = why
            return result
        }
        // A saved scan can outlive a Git add or a newly started agent. Recheck projects
        // immediately before removing their output rather than trusting the cached decision.
        let projectProcesses = item.category == .projects ? ProcessTable.current(.init(cpu: false)) : nil
        let liveSessionIDs = item.category == .aiSessions
            ? Set(ClaudeSessions.live(AgentHome(home: g.home)).map(\.sessionId)) : []
        let resumeProcesses = item.category == .aiSessions ? (processTable ?? ProcessTable.current(.init(cpu: false))).entries : []
        let resumedIDs = Set(resumeProcesses.flatMap { process -> [String] in
            guard ProcessTable.agentNames.contains(process.name) || ProcessTable.agentNames.contains(((process.argv.first ?? "") as NSString).lastPathComponent) else { return [] }
            var ids: [String] = []
            for (index, argument) in process.argv.enumerated() where ["resume", "--resume", "--session"].contains(argument) {
                if index + 1 < process.argv.count, process.argv[index + 1].count >= 8 { ids.append(process.argv[index + 1]) }
            }
            return ids
        })
        var openFiles: OpenFiles?? = nil
        // Rechecked as removal goes (an app may start meanwhile), but with the paths resolved once
        // and the process list read at most once a second: per path, 1,600 sessions took 8 minutes.
        let locations = item.paths.map(Guard.deletionLocation)
        // The item-wide answer depends only on the process list, so it is recomputed when that is reread.
        var processesRead = Date()
        var itemRefusal = refusal(item, mode: mode, processes: processTable ?? ProcessTable.current(.init(cpu: false)), locations: locations)
        func currentRefusal() -> String? {
            if processTable == nil, Date().timeIntervalSince(processesRead) >= 1 {
                itemRefusal = refusal(item, mode: mode, processes: ProcessTable.current(.init(cpu: false)), locations: locations)
                processesRead = Date()
            }
            return itemRefusal
        }
        for path in item.paths {
            if let why = ToolCleanup.isBrowserOldVersion(item) ? ToolCleanup.oldVersionRefusal(path) : g.refusal(path) { result.failed[path] = why; continue }
            if whitelist.protects(path) { result.whitelisted = (result.whitelisted ?? []) + [path]; continue }
            guard FS.exists(path) else { continue }
            if item.category == .aiSessions {
                let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                if liveSessionIDs.contains(name) || resumedIDs.contains(where: { name == $0 || name.hasSuffix("-" + $0) }) {
                    result.failed[path] = tr("this session is running")
                    continue
                }
            }
            if item.category == .projects {
                let dir = item.group ?? (path as NSString).deletingLastPathComponent
                guard path.hasPrefix(dir + "/") else { result.failed[path] = "project path does not match its group"; continue }
                let name = String(path.dropFirst(dir.count + 1))
                if Projects.protectedArtifacts(dir, [name]).contains(name) {
                    result.failed[path] = "Git tracks this output, or its status could not be verified"
                    continue
                }
                if let processes = projectProcesses,
                   processes.agentDirectories().contains(where: { $0 == dir || $0.hasPrefix(dir + "/") ||
                       (dir.hasPrefix($0 + "/") && ProjectSignals.isRepoRoot($0, containing: dir)) }) {
                    result.failed[path] = "an agent is running in it"
                    continue
                }
            }
            let size = FS.size(path, trackNewest: scannedAt != nil)
            if let t = scannedAt, let n = size.newest, n > t.addingTimeInterval(1) {
                result.failed[path] = "modified since the scan"
                continue
            }
            if let why = currentRefusal() {
                result.failed[path] = why
                continue
            }
            // Resolve ancestors again after sizing: a changed parent alias must not redirect removal.
            if let why = ToolCleanup.isBrowserOldVersion(item) ? ToolCleanup.oldVersionRefusal(path) : g.refusal(path) { result.failed[path] = why; continue }
            // The same file as scanned, and nothing running holds it or anything inside it open.
            if let scanned = item.identities?[path], FileIdentity.of(path) != scanned {
                result.failed[path] = tr("replaced since the scan")
                continue
            }
            if openFiles == nil { openFiles = .some(OpenFiles.current()) }
            guard let snapshot = openFiles ?? nil else {
                result.failed[path] = tr("could not check whether a program is using it")
                continue
            }
            if let holder = snapshot.holder(of: path) {
                result.failed[path] = tr("%1$@ has files open here", holder.name)
                continue
            }
            // Items already in the Trash can only be removed for good.
            let inTrash = path.hasPrefix(g.home + "/.Trash/")
            let originalIdentity = FileIdentity.of(path)
            var backupName: String?
            var registration: WorktreeCleanup.Registration?
            do {
                if item.category == .agentWorktrees {
                    registration = try WorktreeCleanup.registration(path, processes: processTable ?? ProcessTable.current(.init(cpu: false)))
                }
                if trash && !inTrash {
                    if let registration { backupName = try WorktreeCleanup.prepare(registration) }
                    let destination = try operations.trash(path)
                    result.removed.append(path); result.bytes += size.bytes
                    result.trashedAllocatedBytes = (result.trashedAllocatedBytes ?? 0) + size.allocated
                    guard let identity = FileIdentity.of(destination.path) else { throw WorktreeCleanup.Refusal("Trash destination identity could not be read") }
                    let entry = TrashBatch.Entry(original: path, destination: destination.path, identity: identity, bytes: size.bytes,
                                                registrationBackup: backupName.map { destination.path + "/" + $0 },
                                                registrationOriginal: registration?.metadata)
                    do {
                        try TrashBatches.append(entry, id: batchID, home: g.home)
                        result.trashBatchID = batchID
                    } catch { result.failed["batch/" + path] = "moved to " + destination.path + ", but batch recording failed: " + error.localizedDescription }
                    if let registration {
                        do { try WorktreeCleanup.unregister(registration) }
                        catch { result.failed["git/" + path] = "files preserved in Trash; Git cleanup failed: " + String(describing: error) }
                    }
                } else {
                    if let registration { try WorktreeCleanup.remove(registration) }
                    else { try operations.remove(path) }
                    result.removed.append(path); result.bytes += size.bytes
                }
            } catch {
                if !trash { accountPartialRemoval(path, before: size, identity: originalIdentity, result: &result) }
                if let backupName, FS.exists(path + "/" + backupName) { try? FileManager.default.removeItem(atPath: path + "/" + backupName) }
                result.failed[path] = (error as NSError).localizedDescription
            }
        }
        // Things only their own tool may remove: report the item's size once every command succeeded.
        if let commands = item.commands, !commands.isEmpty {
            if let why = refusal(item, mode: mode, processes: processTable ?? ProcessTable.current(.init(cpu: false))) {
                result.failed[item.id] = why
                return result
            }
            var ok = true
            let measuredBefore = item.measure.map { FS.size($0) }
            for argv in commands {
                if let why = Simulators.currentRemovalRefusal([argv], requireUnavailable: item.id == "simulator-unavailable") {
                    ok = false; result.failed[argv.joined(separator: " ")] = why
                    break
                }
                let (status, output) = Shell.exec(argv, timeout: 180)
                let line = argv.joined(separator: " ")
                if status == 0 { result.removed.append("ran: " + line) } else { ok = false; result.failed[line] = output.isEmpty ? "exit \(status)" : output; break }
            }
            if ok, let before = measuredBefore, let paths = item.measure {
                result.bytes += max(0, before.bytes - FS.size(paths).bytes)
            } else if ok { result.bytes += item.bytes }
        }
        if item.category != .agentWorktrees, !result.removed.isEmpty, let cmds = item.afterClean {
            for c in cmds {
                let (status, output) = Shell.exec(["sh", "-c", c], timeout: 30)
                if status != 0 { result.failed["afterClean/" + c] = output.isEmpty ? "post-clean command failed" : output }
            }
        }
        return result
    }

    /// A failed recursive delete may already have removed children. Do not call that zero.
    static func accountPartialRemoval(_ path: String, before: TreeSize, identity: String?, result: inout CleanResult) {
        let after = FS.size(path)
        let same = FileIdentity.of(path) == identity || !FS.exists(path)
        if !same || before.denied || after.denied || after.incomplete {
            result.bytesIncomplete = true
            result.partialRemoved = (result.partialRemoved ?? []) + [path]
            return
        }
        let estimate = max(0, before.bytes - after.bytes)
        if estimate > 0 || before.allocated > after.allocated {
            result.bytes += estimate
            result.partialRemoved = (result.partialRemoved ?? []) + [path]
        }
    }

    static func log(_ r: CleanResult, item: CleanItem, home: String) {
        let url = logURL(home: home)
        journal(r, item: item, home: home)
        let f = ISO8601DateFormatter()
        var lines = r.removed.map { "\(f.string(from: Date())) \(r.trashed ? "trash" : "delete") \(item.id) \($0)" }
        lines += (r.partialRemoved ?? []).map { "\(f.string(from: Date())) partial \(item.id) \($0) (estimated removed bytes included; complete estimate=\(r.bytesIncomplete != true))" }
        lines += r.failed.map { "\(f.string(from: Date())) failed \(item.id) \($0.key): \($0.value)" }
        guard !lines.isEmpty else { return }
        lines.append("\(f.string(from: Date())) result \(item.id) outcome=\(r.outcome ?? "unknown") estimatedRemovedBytes=\(r.bytes) estimateIncomplete=\(r.bytesIncomplete == true) trashBatch=\(r.trashBatchID ?? "none")")
        if let observation = r.spaceObservation, let delta = observation.availableChangeBytes {
            lines.append("\(f.string(from: Date())) disk-change \(item.id) \(delta) bytes (includes other disk activity)")
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8)!
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}

extension Cleaner {
    /// Every cleanup, uninstall, hand-picked Trash move and Trash-batch empty goes through `log`;
    /// this mirrors it into the shared operation history, with where it can be undone.
    static func journal(_ r: CleanResult, item: CleanItem, home: String) {
        let feature: String, action: String
        switch r.id {
        case let id where id.hasPrefix("app-data:"): (feature, action) = ("apps", "removeData")
        case let id where id.hasPrefix("app:"): (feature, action) = ("apps", "uninstall")
        case let id where id.hasPrefix("leftovers:"): (feature, action) = ("apps", "remove")
        case "manual": (feature, action) = ("space", "trash")
        case let id where id.hasPrefix("trash-batch/"): (feature, action) = ("clean", "emptyTrash")
        default: (feature, action) = ("clean", r.trashed ? "trash" : "delete")
        }
        let partial = Set(r.partialRemoved ?? [])
        // Per-path sizes are not kept by the cleaner; a single removed path carries the total.
        let single = r.removed.count == 1 && r.bytesIncomplete != true
        var items = r.removed.map { OperationRecord.Item(target: $0, bytes: single ? r.bytes : nil, status: partial.contains($0) ? "partial" : "done") }
        items += partial.subtracting(r.removed).sorted().map { OperationRecord.Item(target: $0, status: "partial") }
        items += r.failed.sorted { $0.key < $1.key }.map { OperationRecord.Item(target: $0.key, status: "failed", detail: $0.value) }
        let undo: OperationRecord.Undo? = r.trashBatchID.map { .init(kind: "trashBatch", ref: $0) }
            ?? (r.trashed && action != "emptyTrash" && !r.removed.isEmpty ? .init(kind: "trash", ref: "") : nil)
        var record = OperationRecord(feature: feature, action: action, subject: item.id == r.id ? item.title : item.id, items: items, undo: undo)
        if !single, !r.removed.isEmpty {
            record.bytes = r.bytes
            record.bytesIncomplete = r.bytesIncomplete == true ? true : nil
        }
        OperationJournal.record(record, home: home)
    }
}

// MARK: - Shell

enum Shell {
    /// Bounded output, with timeout/cancellation limited to this command's own child.
    static func exec(_ argv: [String], timeout: TimeInterval, cancellation: ScanCancellation? = nil) -> (Int32, String) {
        let result = CommandRunner.run("/usr/bin/env", arguments: argv, timeout: timeout,
                                       cancelled: { cancellation?.isCancelled == true })
        if result.cancelled { return (-1, "cancelled") }
        if result.timedOut { return (-1, "timed out") }
        if result.truncated { return (-1, "command output exceeded the limit") }
        return (result.status, result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Read-only scan commands inherit the current scan token unless explicitly supplied.
    @discardableResult
    static func run(_ command: String, timeout: TimeInterval = 10, cancellation: ScanCancellation? = nil) -> String? {
        let token = cancellation ?? ScanCancellation.current
        let result = CommandRunner.run("/bin/sh", arguments: ["-c", command], timeout: timeout,
                                       captureError: false, cancelled: { token?.isCancelled == true })
        guard result.status == 0, !result.timedOut, !result.cancelled, !result.truncated else { return nil }
        return result.output
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}


/// Lets a running scan be stopped. Synchronous walks inherit a thread-scoped token;
/// work dispatched to another thread must explicitly install its owning scan's token.
public final class ScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    private static let currentKey = "dev.thermo.scanCancellation"
    public static var current: ScanCancellation? {
        get { Thread.current.threadDictionary[currentKey] as? ScanCancellation }
        set {
            if let newValue { Thread.current.threadDictionary[currentKey] = newValue }
            else { Thread.current.threadDictionary.removeObject(forKey: currentKey) }
        }
    }

    /// Synchronous scope only: do not suspend or dispatch work without forwarding the token.
    static func withCurrent<T>(_ token: ScanCancellation?, _ body: () throws -> T) rethrows -> T {
        let previous = current
        current = token
        defer { current = previous }
        return try body()
    }
}

/// Narrow injection seam for failure/Trash tests; production always uses macOS operations.
struct RemovalOperations {
    var trash: (String) throws -> URL
    var remove: (String) throws -> Void
    static let live = RemovalOperations(trash: { path in
        var destination: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &destination)
        guard let destination else { throw NSError(domain: "Thermo", code: 1, userInfo: [NSLocalizedDescriptionKey: "macOS did not return the Trash destination"]) }
        return destination as URL
    }, remove: { try FileManager.default.removeItem(atPath: $0) })
}
