import CryptoKit
import Darwin
import Foundation
import ThermoL10n

/// Files with identical contents. Found by size first, then a hash of the first and last 64 KB,
/// then a full SHA-256, so only real candidates are read in full.
public struct DuplicateGroup: Codable, Sendable, Identifiable, Hashable {
    public var id: String { hash }
    public var hash: String
    /// Size of one copy.
    public var size: Int64
    /// Oldest first: the first is the one suggested to keep.
    public var paths: [String]
    /// What removing every copy but the first gives back (APFS clones share their blocks: ~0).
    public var reclaimable: Int64
}

public enum Duplicates {
    /// Folders skipped by default: build output, dependencies, app data and version control, where
    /// identical files are expected and removing one breaks something.
    public static let skippedNames: Set<String> = ["node_modules", ".git", ".svn", ".hg", ".build", "target", ".venv", "venv",
                                                   "__pycache__", ".gradle", "DerivedData", "Pods", ".Trash", ".cache", ".npm",
                                                   ".cargo", ".rustup", ".m2", "Library"]
    public static let skippedExtensions: Set<String> = ["app", "photoslibrary", "musiclibrary", "tvlibrary", "framework",
                                                        "bundle", "xcarchive", "pkg", "dmg", "sparsebundle"]

    public struct Progress: Sendable {
        public var stage: String
        public var done: Int
        public var total: Int
    }

    public static func find(in roots: [String], minimum: Int64 = 1 << 20, cancellation: ScanCancellation = ScanCancellation(),
                            progress: ((Progress) -> Void)? = nil) -> [DuplicateGroup] {
        // 1. Every regular file above the minimum, by exact length. Hard links are one file.
        var bySize: [Int64: [(path: String, modified: Date)]] = [:]
        var seenInodes = Set<String>()
        var listed = 0
        func visit(_ dir: String) {
            guard !cancellation.isCancelled, let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
            for name in names {
                if cancellation.isCancelled { return }
                let path = dir + "/" + name
                var st = stat()
                guard lstat(path, &st) == 0 else { continue }
                switch st.st_mode & S_IFMT {
                case S_IFDIR:
                    if skippedNames.contains(name) || skippedExtensions.contains((name as NSString).pathExtension.lowercased()) { continue }
                    visit(path)
                case S_IFREG:
                    guard Int64(st.st_size) >= minimum else { continue }
                    if !seenInodes.insert("\(st.st_dev):\(st.st_ino)").inserted { continue }
                    bySize[Int64(st.st_size), default: []].append((path, Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))))
                    listed += 1
                    if listed % 500 == 0 { progress?(Progress(stage: tr("Listing files"), done: listed, total: 0)) }
                default: continue
                }
            }
        }
        for root in roots { visit((root as NSString).standardizingPath) }

        // 2. Same size: compare the ends, then everything.
        let candidates = bySize.filter { $0.value.count > 1 }
        let total = candidates.values.reduce(0) { $0 + $1.count }
        var done = 0
        var groups: [DuplicateGroup] = []
        for (size, files) in candidates.sorted(by: { $0.key > $1.key }) {
            if cancellation.isCancelled { break }
            var byEnds: [String: [(path: String, modified: Date)]] = [:]
            for f in files {
                if let h = endsHash(f.path, size: size) { byEnds[h, default: []].append(f) }
                done += 1
            }
            progress?(Progress(stage: tr("Comparing contents"), done: done, total: total))
            for (_, same) in byEnds where same.count > 1 {
                var byFull: [String: [(path: String, modified: Date)]] = [:]
                for f in same {
                    if cancellation.isCancelled { break }
                    if let h = fullHash(f.path, cancellation: cancellation) { byFull[h, default: []].append(f) }
                }
                for (hash, copies) in byFull where copies.count > 1 {
                    let ordered = copies.sorted { ($0.modified, $0.path.count, $0.path) < ($1.modified, $1.path.count, $1.path) }
                    let extra = ordered.dropFirst().reduce(Int64(0)) { sum, f in
                        sum + (BulkWalk.fileSize(f.path)?.privateSize ?? size)
                    }
                    groups.append(DuplicateGroup(hash: hash, size: size, paths: ordered.map(\.path), reclaimable: extra))
                }
            }
        }
        return groups.sorted { $0.reclaimable > $1.reclaimable }
    }

    static func endsHash(_ path: String, size: Int64) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let chunk = 64 * 1024
        var data = h.readData(ofLength: chunk)
        if size > Int64(chunk * 2) {
            try? h.seek(toOffset: UInt64(size) - UInt64(chunk))
            data.append(h.readData(ofLength: chunk))
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func fullHash(_ path: String, cancellation: ScanCancellation) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            if cancellation.isCancelled { return nil }
            let data = h.readData(ofLength: 1 << 20)
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Moving things a person picked by hand (in the space browser, the large files list or the
/// duplicates) to the Trash. Looser than cleanup's `Guard`, because each path was chosen and shown
/// before it moves: Documents or Downloads may go, but never the folders themselves, keys and
/// credentials, iCloud, mail, photo libraries' insides, git metadata or anything outside home.
public enum ManualRemoval {
    public static func refusal(_ path: String, home: String = NSHomeDirectory(), whitelist: Whitelist? = nil) -> String? {
        if !path.hasPrefix("/") || path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) { return tr("not a full path") }
        if let why = Whitelist.refusal(path, home: home, whitelist: whitelist) { return why }
        let real = Guard.deletionLocation(path)
        let canonicalHome = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        let p = real.hasPrefix(canonicalHome + "/") ? home + real.dropFirst(canonicalHome.count) : real
        guard p.hasPrefix(home + "/") else { return tr("outside your home folder") }
        let g = Guard(home: home)
        // The well-known folders themselves (Documents, Library, ~/.claude …) and anything holding one.
        for x in g.protected where p == x || x.hasPrefix(p + "/") { return tr("a folder macOS or your tools rely on") }
        let sealed = [".ssh", ".gnupg", ".aws", ".kube", ".docker/config.json", ".netrc", ".config/gh", "Library/Keychains",
                      "Library/Mail", "Library/Messages", "Library/Mobile Documents", "Library/CloudStorage", "Library/Photos",
                      ".claude/.credentials.json", ".codex/auth.json", ".claude/agent-memory", ".codex/memories"].map { home + "/" + $0 }
        for x in sealed where p == x || p.hasPrefix(x + "/") { return tr("keys, credentials, mail or iCloud files") }
        if p.contains(".photoslibrary/") { return tr("inside a photo library; use Photos") }
        if p.hasSuffix("/.git") || p.contains("/.git/") { return tr("git metadata") }
        return nil
    }

    /// Moves each path to the Trash after checking it again: allowed, still there, not held open by a running program.
    public static func trash(_ paths: [String], sizes: [String: Int64] = [:], home: String = NSHomeDirectory()) -> CleanResult {
        trash(paths, sizes: sizes, home: home, move: RemovalOperations.live.trash)
    }

    static func trash(_ paths: [String], sizes: [String: Int64], home: String, move: (String) throws -> URL) -> CleanResult {
        var result = CleanResult(id: "manual", trashed: true)
        let batchID = UUID().uuidString
        let open = OpenFiles.current()
        var whitelist: Whitelist?
        do { whitelist = try Whitelist.load(home: home) } catch { for path in paths { result.failed[path] = Whitelist.unreadable(error) } }
        for path in paths where whitelist != nil {
            if whitelist?.protects(path) == true { result.whitelisted = (result.whitelisted ?? []) + [path]; continue }
            if let why = refusal(path, home: home, whitelist: whitelist) { result.failed[path] = why; continue }
            guard FileManager.default.fileExists(atPath: path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil else { continue }
            guard let open else { result.failed[path] = tr("could not check whether a program is using it"); continue }
            if let h = open.holder(of: path) { result.failed[path] = tr("%1$@ has files open here", h.name); continue }
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
        if !result.removed.isEmpty {
            ScanReportCache.invalidate(home: home)
            SpaceOverview.invalidate(home: home)
        }
        Cleaner.log(result, item: CleanItem(id: "manual", category: .system, title: tr("Picked by hand"), safety: .review,
                                            paths: paths), to: Cleaner.logURL(home: home))
        return result
    }
}
