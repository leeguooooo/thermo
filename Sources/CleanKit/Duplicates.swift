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
    public var reviewIdentities: [String: String]? = nil
    public var privateBytes: [String: Int64]? = nil
    public var reclaimableState: AppSizeState? = nil
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
        var bySize: [Int64: [(path: String, modified: Date, identity: String)]] = [:]
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
                    guard let identity = ManualRemoval.reviewIdentity(path) else { continue }
                    var after = stat()
                    guard lstat(path, &after) == 0, AppDataReviewIdentity.text(st) == AppDataReviewIdentity.text(after),
                          ManualRemoval.reviewIdentity(path) == identity else { continue }
                    bySize[Int64(st.st_size), default: []].append((path, Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)), identity))
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
            var byEnds: [String: [(path: String, modified: Date, identity: String)]] = [:]
            for f in files {
                if let h = endsHash(f.path, size: size, expected: f.identity) { byEnds[h, default: []].append(f) }
                done += 1
            }
            progress?(Progress(stage: tr("Comparing contents"), done: done, total: total))
            for (_, same) in byEnds where same.count > 1 {
                var byFull: [String: [(path: String, modified: Date, identity: String)]] = [:]
                for f in same {
                    if cancellation.isCancelled { break }
                    if let h = fullHash(f.path, cancellation: cancellation, expected: f.identity, size: size) { byFull[h, default: []].append(f) }
                }
                for (hash, copies) in byFull where copies.count > 1 {
                    let ordered = copies.sorted { ($0.modified, $0.path.count, $0.path) < ($1.modified, $1.path.count, $1.path) }
                    guard ordered.allSatisfy({ ManualRemoval.reviewIdentity($0.path) == $0.identity }) else { continue }
                    var privateBytes: [String: Int64] = [:]
                    for file in ordered {
                        if let bytes = BulkWalk.fileSize(file.path)?.privateSize, bytes >= 0 { privateBytes[file.path] = bytes }
                    }
                    guard ordered.allSatisfy({ ManualRemoval.reviewIdentity($0.path) == $0.identity }) else { continue }
                    let extra = ordered.dropFirst().reduce(Int64(0)) { $0 + (privateBytes[$1.path] ?? 0) }
                    let quality: AppSizeState = ordered.dropFirst().allSatisfy { privateBytes[$0.path] != nil } ? .complete : (extra > 0 ? .incomplete : .unavailable)
                    groups.append(DuplicateGroup(hash: hash, size: size, paths: ordered.map(\.path), reclaimable: extra,
                        reviewIdentities: Dictionary(uniqueKeysWithValues: ordered.map { ($0.path, $0.identity) }),
                        privateBytes: privateBytes, reclaimableState: quality))
                }
            }
        }
        return groups.sorted { $0.reclaimable > $1.reclaimable }
    }

    static func endsHash(_ path: String, size: Int64, expected: String? = nil) -> String? {
        verifiedHash(path, size: size, expected: expected, cancellation: nil, endsOnly: true)
    }

    static func fullHash(_ path: String, cancellation: ScanCancellation, expected: String? = nil, size: Int64? = nil) -> String? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return verifiedHash(path, size: size ?? Int64(st.st_size), expected: expected, cancellation: cancellation, endsOnly: false)
    }

    private static func verifiedHash(_ path: String, size: Int64, expected: String?, cancellation: ScanCancellation?, endsOnly: Bool) -> String? {
        guard size >= 0, cancellation?.isCancelled != true,
              let identity = expected ?? ManualRemoval.reviewIdentity(path), ManualRemoval.reviewIdentity(path) == identity else { return nil }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size == size, AppDataReviewIdentity.of(path) == AppDataReviewIdentity.text(before),
              ManualRemoval.reviewIdentity(path) == identity else { return nil }
        do {
            var hasher = SHA256()
            if endsOnly {
                guard let first = try handle.read(upToCount: Int(min(size, 65_536))), first.count == min(size, 65_536) else { return nil }
                hasher.update(data: first)
                if size > 131_072 {
                    try handle.seek(toOffset: UInt64(size - 65_536))
                    guard let last = try handle.read(upToCount: 65_536), last.count == 65_536 else { return nil }
                    hasher.update(data: last)
                }
            } else {
                var remaining = size
                while remaining > 0 {
                    if cancellation?.isCancelled == true { return nil }
                    guard let data = try handle.read(upToCount: Int(min(remaining, 1 << 20))), !data.isEmpty else { return nil }
                    hasher.update(data: data); remaining -= Int64(data.count)
                }
                guard (try handle.read(upToCount: 1))?.isEmpty != false else { return nil }
            }
            guard cancellation?.isCancelled != true, fstat(fd, &after) == 0,
                  AppDataReviewIdentity.text(before) == AppDataReviewIdentity.text(after), AppDataReviewIdentity.of(path) == AppDataReviewIdentity.text(after), ManualRemoval.reviewIdentity(path) == identity else { return nil }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch { return nil }
    }

}

/// Moving things a person picked by hand (in the space browser, the large files list or the
/// duplicates) to the Trash. Looser than cleanup's `Guard`, because each path was chosen and shown
/// before it moves: Documents or Downloads may go, but never the folders themselves, keys and
/// credentials, iCloud, mail, photo libraries' insides, git metadata or anything outside home.
public enum ManualRemoval {
    /// Opaque metadata token for the selected entry and its actual parent.
    /// This does not seal recursive directory contents.
    public static func reviewIdentity(_ path: String) -> String? {
        guard let entry = AppDataReviewIdentity.of(path) else { return nil }
        let location = Guard.deletionLocation(path)
        guard let parent = FileIdentity.of((location as NSString).deletingLastPathComponent) else { return nil }
        return SHA256.hash(data: Data((entry + "\n" + location + "\n" + parent).utf8)).map { String(format: "%02x", $0) }.joined()
    }
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
    public static func trash(_ paths: [String], sizes: [String: Int64] = [:], home: String = NSHomeDirectory(), incompletePaths: Set<String> = [],
                             reviewIdentities: [String: String]? = nil, requiredIdentities: [String: String] = [:]) -> CleanResult {
        trash(paths, sizes: sizes, home: home, incompletePaths: incompletePaths, reviewIdentities: reviewIdentities, requiredIdentities: requiredIdentities, move: RemovalOperations.live.trash)
    }

    static func trash(_ paths: [String], sizes: [String: Int64], home: String, incompletePaths: Set<String> = [],
                       reviewIdentities: [String: String]? = nil, requiredIdentities: [String: String] = [:], openFiles: () -> OpenFiles? = { OpenFiles.current() },
                       move: (String) throws -> URL) -> CleanResult {
        var result = CleanResult(id: "manual", trashed: true)
        let batchID = UUID().uuidString
        let paths = Array(Set(paths)).sorted()
        let reviewed = reviewIdentities ?? paths.reduce(into: [String: String]()) { $0[$1] = reviewIdentity($1) }
        for (index, path) in paths.enumerated() {
            let open = openFiles()
            let whitelist: Whitelist
            do { whitelist = try Whitelist.load(home: home) }
            catch {
                for remaining in paths[index...] { result.failed[remaining] = Whitelist.unreadable(error) }
                break
            }
            if whitelist.protects(path) { result.whitelisted = (result.whitelisted ?? []) + [path]; continue }
            if let why = refusal(path, home: home, whitelist: whitelist) { result.failed[path] = why; continue }
            guard FileManager.default.fileExists(atPath: path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil else { continue }
            guard let open else { result.failed[path] = tr("could not check whether a program is using it"); continue }
            if let h = open.holder(of: path) { result.failed[path] = tr("%1$@ has files open here", h.name); continue }
            if requiredIdentities.contains(where: { required in
                reviewIdentity(required.key) != required.value || paths.contains { required.key == $0 || required.key.hasPrefix($0 + "/") }
            }) {
                for remaining in paths[index...] { result.failed[remaining] = tr("A retained duplicate changed or disappeared; compare the files again") }
                break
            }
            guard let identity = reviewed[path], reviewIdentity(path) == identity else {
                result.failed[path] = tr("The selected item changed after review; select it again")
                continue
            }
            do {
                let unrecorded = try TrashBatches.trash(path, bytes: sizes[path] ?? 0, id: batchID, home: home, move: move)
                result.removed.append(path)
                if incompletePaths.contains(path) || sizes[path] == nil { result.bytesIncomplete = true }
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
            if !SpaceLens.invalidateCache(at: SpaceLens.cacheURL(home: home)) {
                result.failed["cache"] = tr("The old space cache could not be cleared; scan again before using saved results")
            }
        }
        Cleaner.log(result, item: CleanItem(id: "manual", category: .system, title: tr("Picked by hand"), safety: .review,
                                            paths: paths), home: home)
        return result
    }
}
