import AgentCore
import CryptoKit
import Darwin
import Foundation

public struct SSHArchiveDestination: Codable, Sendable, Equatable {
    public let host: String
    public let path: String

    public init(_ specification: String) throws {
        guard let separator = specification.firstIndex(of: ":") else {
            throw ArchiveFailure("Use an SSH alias and an absolute archive path: nas:/archive/project.tar")
        }
        let host = String(specification[..<separator])
        let path = String(specification[specification.index(after: separator)...])
        let characters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@")
        guard !host.isEmpty, !host.hasPrefix("-"), host.unicodeScalars.allSatisfy(characters.contains),
              path.hasPrefix("/"), path.hasSuffix(".tar"), !path.contains("\0"), !path.contains("\n"),
              !path.split(separator: "/").contains("..") else {
            throw ArchiveFailure("Invalid SSH alias or archive path")
        }
        self.host = host; self.path = path
    }
}

public struct ArchiveFailure: Error, CustomStringConvertible, LocalizedError {
    public let description: String
    public var errorDescription: String? { description }
    public init(_ description: String) { self.description = description }
}

public struct ArchivePlan: Codable, Sendable {
    public let source: String
    public let destination: SSHArchiveDestination
    public let files: Int
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let payloadBytes: Int64
    public let developmentEnvironment: Bool
    public let removesLocal: Bool
}

public struct ArchiveReceipt: Codable, Sendable {
    public let version: Int
    public let plan: ArchivePlan
    public let sha256: String
    public let archiveBytes: Int64
    public let verifiedAt: Date
    public var localRemoved: Bool
    public let restoreDirectory: String
    public let diskSpace: DiskSpaceObservation
}

/// Local tar + a checksummed SSH stream. No rsync service or remote Python tar parser is needed.
/// Archive roots, including a VM's holes and symlinks, retain their native tar metadata.
public enum VerifiedArchive {
    struct Entry: Equatable {
        let path: String
        let device: dev_t
        let inode: ino_t
        let mode: mode_t
        let size: Int64
        let modified: timespec
        let changed: timespec

        static func == (a: Self, b: Self) -> Bool {
            a.path == b.path && a.device == b.device && a.inode == b.inode && a.mode == b.mode && a.size == b.size
                && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
                && a.changed.tv_sec == b.changed.tv_sec && a.changed.tv_nsec == b.changed.tv_nsec
        }
        var directory: Bool { mode & S_IFMT == S_IFDIR }
    }

    struct Snapshot {
        let entries: [Entry]
        let logical: Int64
        let allocated: Int64
        let payload: Int64
    }

    /// An internal local-shell transport is used only for synthetic integration tests.
    public struct Transport {
        let arguments: (String) -> [String]
        public init(host: String) {
            arguments = { ["/usr/bin/ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "--", host, $0] }
        }
        init(arguments: @escaping (String) -> [String]) { self.arguments = arguments }
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func snapshot(_ source: String) throws -> Snapshot {
        var entries: [Entry] = []; var logical: Int64 = 0; var allocated: Int64 = 0; var payload: Int64 = 0
        var seen = Set<String>()
        func visit(_ path: String) throws {
            var s = stat()
            guard lstat(path, &s) == 0 else { throw ArchiveFailure("Cannot inspect \(path)") }
            let type = s.st_mode & S_IFMT
            guard [S_IFDIR, S_IFREG, S_IFLNK].contains(type) else {
                throw ArchiveFailure("Source contains a socket or special file; leave it in place: \(path)")
            }
            entries.append(Entry(path: path, device: s.st_dev, inode: s.st_ino, mode: s.st_mode, size: s.st_size,
                                 modified: s.st_mtimespec, changed: s.st_ctimespec))
            if type == S_IFDIR {
                for name in try FileManager.default.contentsOfDirectory(atPath: path).sorted() { try visit(path + "/" + name) }
            } else if type == S_IFREG, seen.insert("\(s.st_dev):\(s.st_ino)").inserted {
                logical += s.st_size; allocated += Int64(s.st_blocks) * 512
                payload += try dataBytes(path, size: s.st_size, allocated: Int64(s.st_blocks) * 512)
            }
        }
        try visit(source)
        return Snapshot(entries: entries, logical: logical, allocated: allocated, payload: payload)
    }

    /// Sparse ranges, not virtual EOF. Compressed files can have more data than their allocation.
    static func dataBytes(_ path: String, size: Int64, allocated: Int64) throws -> Int64 {
        if size <= allocated { return size }
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw ArchiveFailure("Cannot inspect sparse file: \(path)") }
        defer { close(fd) }
        var offset: off_t = 0; var total: Int64 = 0
        while offset < size {
            let start = lseek(fd, offset, SEEK_DATA)
            if start < 0 {
                if errno == ENXIO { break }
                throw ArchiveFailure("Filesystem cannot report sparse ranges: \(path)")
            }
            let end = lseek(fd, start, SEEK_HOLE)
            guard end > start else { throw ArchiveFailure("Invalid sparse range: \(path)") }
            total += min(end, size) - start; offset = end
        }
        return total
    }

    static func sourcePath(_ path: String, removeLocal: Bool, allowDevelopment: Bool) throws -> String {
        let source = (path as NSString).expandingTildeInPath
        let normalized = URL(fileURLWithPath: source).standardizedFileURL.path
        guard FS.isDirectory(normalized), !FileManager.default.destinationIsSymbolicLink(normalized),
              let resolved = realpath(normalized, nil) else {
            throw ArchiveFailure("Choose a real source directory")
        }
        let canonical = String(cString: resolved); free(resolved)
        if removeLocal {
            guard !["/", NSHomeDirectory(), "/Users", "/Library", "/System", "/Applications", "/opt", "/private"].contains(canonical),
                  canonical != NSHomeDirectory() + "/Library" else { throw ArchiveFailure("Cannot remove a system or home root") }
            if DevelopmentPreservation.environment(canonical), !allowDevelopment {
                throw ArchiveFailure("Development environment is preserved. Only use --inactive-development after confirming it is no longer needed.")
            }
            if canonical.hasPrefix(NSHomeDirectory() + "/") {
                if let refusal = ManualRemoval.refusal(canonical) { throw ArchiveFailure(refusal) }
            } else if !allowDevelopment || !canonical.hasPrefix("/opt/homebrew/") {
                throw ArchiveFailure("Local removal is limited to your home or an explicitly inactive Homebrew environment")
            }
        }
        return canonical
    }

    public static func plan(source: String, destination: SSHArchiveDestination, removeLocal: Bool = false,
                            allowDevelopment: Bool = false) throws -> ArchivePlan {
        let path = try sourcePath(source, removeLocal: removeLocal, allowDevelopment: allowDevelopment)
        let measured = try snapshot(path)
        return makePlan(path, destination, measured, removeLocal)
    }

    private static func makePlan(_ path: String, _ target: SSHArchiveDestination, _ measured: Snapshot, _ removal: Bool) -> ArchivePlan {
        ArchivePlan(source: path, destination: target, files: measured.entries.filter { !$0.directory }.count,
                    logicalBytes: measured.logical, allocatedBytes: measured.allocated, payloadBytes: measured.payload,
                    developmentEnvironment: DevelopmentPreservation.environment(path), removesLocal: removal)
    }

    static func ensureIdle(_ source: String) throws {
        let result = try Running(["/usr/sbin/lsof", "-nP", "+D", source]).finish()
        guard result.status == 1, result.output.isEmpty, result.error.isEmpty else {
            throw ArchiveFailure("Source is open or its ownership cannot be verified; stop its app and retry")
        }
    }

    public static func archive(source: String, destination: SSHArchiveDestination, removeLocal: Bool = false,
                               allowDevelopment: Bool = false, progress: ((Int64) -> Void)? = nil) throws -> ArchiveReceipt {
        let remote = destination.host + ":" + destination.path
        do {
            let receipt = try archive(source: source, destination: destination, removeLocal: removeLocal, allowDevelopment: allowDevelopment,
                                      transport: Transport(host: destination.host), idle: ensureIdle, progress: progress)
            OperationJournal.record(OperationRecord(feature: "archive", action: receipt.localRemoved ? "archiveAndRemove" : "archive", subject: remote,
                                                    items: [.init(target: source, bytes: receipt.archiveBytes, status: "done", detail: "sha256 " + receipt.sha256)],
                                                    undo: .init(kind: "archiveManifest", ref: remote + ".manifest.json")))
            return receipt
        } catch {
            OperationJournal.record(OperationRecord(feature: "archive", action: removeLocal ? "archiveAndRemove" : "archive", subject: remote,
                                                    items: [.init(target: source, status: "failed", detail: error.localizedDescription)]))
            throw error
        }
    }

    static func archive(source: String, destination: SSHArchiveDestination, removeLocal: Bool, allowDevelopment: Bool,
                        transport: Transport, idle: (String) throws -> Void, progress: ((Int64) -> Void)? = nil) throws -> ArchiveReceipt {
        let path = try sourcePath(source, removeLocal: removeLocal, allowDevelopment: allowDevelopment)
        try idle(path)
        let before = DiskSpaceSnapshot.measure(path: path)
        let measured = try snapshot(path)
        let plan = makePlan(path, destination, measured, removeLocal)
        let target = destination.path
        let partial = target + ".partial-" + UUID().uuidString
        let parent = (target as NSString).deletingLastPathComponent
        func remote(_ command: String, input: Data? = nil) throws -> Result {
            let process = try Running(transport.arguments(command))
            if let input { try process.input.fileHandleForWriting.write(contentsOf: input) }
            try process.input.fileHandleForWriting.close()
            return try process.finish()
        }
        let setup = try remote("umask 077; mkdir -p \(quote(parent)) && test ! -e \(quote(target)) && test ! -e \(quote(target + ".manifest.json"))")
        guard setup.status == 0 else { throw ArchiveFailure("Archive already exists or destination is unavailable; local files retained") }
        let writer = try Running(transport.arguments("umask 077; set -C; dd bs=1048576 conv=fsync > \(quote(partial))"))
        _ = fcntl(writer.input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let tar = try Running(["/usr/bin/tar", "--read-sparse", "--acls", "--xattrs", "-cpf", "-", "-C", (path as NSString).deletingLastPathComponent, (path as NSString).lastPathComponent], streamOutput: true)
        var hash = SHA256(); var bytes: Int64 = 0
        // Bounds a broken sparse stream and accidental inclusion of a newly created archive.
        let overhead = max(Int64(128 << 20), Int64(measured.entries.count) * 32_768)
        let limit = measured.payload.addingReportingOverflow(overhead)
        guard !limit.overflow else { tar.stop(); writer.stop(); throw ArchiveFailure("Archive size overflow") }
        do {
            while true {
                let block = tar.output.fileHandleForReading.readData(ofLength: 1 << 20)
                if block.isEmpty { break }
                bytes += Int64(block.count)
                guard bytes <= limit.partialValue else { throw ArchiveFailure("Archive unexpectedly expanded sparse data; local files retained") }
                hash.update(data: block)
                try writer.input.fileHandleForWriting.write(contentsOf: block)
                progress?(bytes)
            }
            try writer.input.fileHandleForWriting.close()
            let tarResult = try tar.finish(); let sent = try writer.finish()
            guard tarResult.status == 0, sent.status == 0 else { throw ArchiveFailure("Transfer failed; local files retained") }
        } catch { tar.stop(); writer.stop(); throw error }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let verify = try remote("sha256sum \(quote(partial)) && tar -tf \(quote(partial)) >/dev/null")
        guard verify.status == 0, String(decoding: verify.output, as: UTF8.self).split(whereSeparator: \.isWhitespace).first == Substring(digest) else {
            throw ArchiveFailure("NAS verification failed; local files retained")
        }
        let currentSnapshot = try snapshot(path)
        guard currentSnapshot.entries == measured.entries else {
            let currentByPath = Dictionary(uniqueKeysWithValues: currentSnapshot.entries.map { ($0.path, $0) })
            let changed = measured.entries.first { currentByPath[$0.path] != $0 }?.path
                ?? currentSnapshot.entries.first { entry in !measured.entries.contains { $0.path == entry.path } }?.path ?? path
            throw ArchiveFailure("Source changed during transfer: \(changed); local files retained")
        }
        try idle(path)
        // Hard-link publication never overwrites a concurrently created final archive.
        let publish = try remote("ln \(quote(partial)) \(quote(target)) && rm \(quote(partial))")
        guard publish.status == 0 else { throw ArchiveFailure("Could not publish verified archive; local files retained") }
        var receipt = ArchiveReceipt(version: 1, plan: plan, sha256: digest, archiveBytes: bytes, verifiedAt: Date(),
                                     localRemoved: false, restoreDirectory: (path as NSString).deletingLastPathComponent,
                                     diskSpace: DiskSpaceObservation(before: before, after: DiskSpaceSnapshot.measure(path: path)))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        func saveReceipt(_ value: ArchiveReceipt) throws {
            let temporary = target + ".manifest.partial-" + UUID().uuidString
            let saved = try remote("umask 077; dd bs=65536 conv=fsync > \(quote(temporary)) && mv \(quote(temporary)) \(quote(target + ".manifest.json"))", input: encoder.encode(value))
            guard saved.status == 0 else { throw ArchiveFailure(value.localRemoved
                ? "Verified archive is retained, but its removal receipt could not be updated"
                : "Could not save recovery receipt; local files retained") }
        }
        try saveReceipt(receipt)
        if removeLocal {
            var unlinked = Set<String>()
            for entry in measured.entries.reversed() {
                var current = stat()
                guard lstat(entry.path, &current) == 0 else { throw ArchiveFailure("Source disappeared during removal; remaining files retained") }
                if entry.directory {
                    // rmdir refuses new files; never recursively delete uncaptured data.
                    if rmdir(entry.path) != 0 { throw ArchiveFailure("Source directory is no longer empty; remaining files retained") }
                } else {
                    let now = Entry(path: entry.path, device: current.st_dev, inode: current.st_ino, mode: current.st_mode, size: current.st_size,
                                    modified: current.st_mtimespec, changed: current.st_ctimespec)
                    let identity = "\(entry.device):\(entry.inode)"
                    let unchanged = now == entry || (unlinked.contains(identity) && now.device == entry.device && now.inode == entry.inode
                        && now.mode == entry.mode && now.size == entry.size && now.modified.tv_sec == entry.modified.tv_sec
                        && now.modified.tv_nsec == entry.modified.tv_nsec)
                    guard unchanged, unlink(entry.path) == 0 else { throw ArchiveFailure("Source changed or could not be removed; verified archive retained") }
                    unlinked.insert(identity)
                }
            }
            receipt = ArchiveReceipt(version: receipt.version, plan: plan, sha256: digest, archiveBytes: bytes, verifiedAt: receipt.verifiedAt,
                                     localRemoved: true, restoreDirectory: receipt.restoreDirectory,
                                     diskSpace: DiskSpaceObservation(before: before, after: DiskSpaceSnapshot.measure(path: receipt.restoreDirectory)))
            try saveReceipt(receipt)
        }
        return receipt
    }

    struct Result { let status: Int32; let output: Data; let error: Data }
    final class Buffer: @unchecked Sendable {
        let lock = NSLock(); var data = Data()
        func append(_ bytes: Data) { lock.lock(); defer { lock.unlock() }; data.append(bytes.prefix(max(0, (1 << 20) - data.count))) }
    }
    final class Running {
        let process = Process(); let input = Pipe(); let output = Pipe(); let errors = Pipe()
        let out = Buffer(); let err = Buffer(); let drains = DispatchGroup()
        init(_ arguments: [String], streamOutput: Bool = false) throws {
            process.executableURL = URL(fileURLWithPath: arguments[0]); process.arguments = Array(arguments.dropFirst())
            process.standardInput = input; process.standardOutput = output; process.standardError = errors
            try process.run()
            func drain(_ handle: FileHandle, into buffer: Buffer) {
                drains.enter()
                DispatchQueue.global(qos: .utility).async { [drains] in
                    while true { let bytes = handle.readData(ofLength: 16_384); if bytes.isEmpty { break }; buffer.append(bytes) }
                    drains.leave()
                }
            }
            if !streamOutput { drain(output.fileHandleForReading, into: out) }
            drain(errors.fileHandleForReading, into: err)
            if streamOutput { try input.fileHandleForWriting.close() }
        }
        func finish() throws -> Result {
            process.waitUntilExit(); drains.wait()
            return Result(status: process.terminationStatus, output: out.data, error: err.data)
        }
        func stop() { if process.isRunning { process.terminate() }; try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close() }
    }
}

private extension FileManager {
    func destinationIsSymbolicLink(_ path: String) -> Bool { (try? destinationOfSymbolicLink(atPath: path)) != nil }
}
