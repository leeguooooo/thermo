import AgentCore
import CryptoKit
import Darwin
import Foundation

public struct PreparedNativeUpdate: Sendable {
    public let source: NativeUpdateSource
    public let release: SparkleRelease
    let workspace: String
    let bundle: String
    let original: NativeBundleFacts
    let replacement: NativeBundleFacts
    let workspaceID: String
}

public struct NativeUpdateReceipt: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var target: String
    public var backup: String
    /// prepared | installed | rolledBack | unconfirmed | restoring | restored
    public var phase: String
    public var previousVersion: String { original.version }
    public var installedVersion: String { replacement.version }
    var original: NativeBundleFacts
    var replacement: NativeBundleFacts
    var originalID: String
    var replacementID: String
}

public struct NativeInstallResult: Codable, Sendable {
    public var outcome: String
    public var message: String
    public var receipt: NativeUpdateReceipt?
    public var preservedWorkspace: NativePreservedWorkspace? = nil
    public var workspaceRecordSaved: Bool? = nil
    public var cleanupIssue: String? = nil
    public var additionalPreservedWorkspaces: [NativeWorkspacePreservation]? = nil
    public var workspacePreservations: [NativeWorkspacePreservation] {
        (preservedWorkspace.map { [NativeWorkspacePreservation(workspace: $0, recorded: workspaceRecordSaved == true)] } ?? [])
            + (additionalPreservedWorkspaces ?? [])
    }
}

public struct NativeRecoveryReport: Codable, Sendable {
    public var records: [NativeUpdateReceipt] = []
    public var backups: [NativeBackupUsage]? = nil
    public var workspaces: [NativePreservedWorkspace]? = nil
    public var issues: [String] = []
}

/// User-only installation, with a pinned destination parent and an atomic directory swap.
/// Only an archive signed by the key in the unchanged original app can produce a prepared bundle.
public enum NativeUpdateTransaction {
    static func failure(_ message: String) -> ArchiveFailure { ArchiveFailure(message) }

    static func privateDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var st = stat()
        guard URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path, lstat(path, &st) == 0,
              st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid(), st.st_mode & 0o077 == 0 else {
            throw failure("The update storage is not a private owned directory")
        }
    }

    static func storage(_ home: String, create: Bool = true) throws -> String {
        guard getuid() != 0 else { throw failure("Native application updates must run as the current user, not root") }
        let root = home + "/Library/Application Support/Thermo/app-updates"
        if !create, !FS.exists(root) { throw failure("No native update records exist") }
        try privateDirectory(root)
        return root
    }

    static func targetRefusal(_ path: String, home: String, processes: ProcessTable) -> String? {
        if let why = Guard(home: home).uninstallRefusal(path, bundleIDs: []) { return why }
        var st = stat()
        if lstat(path, &st) != 0 || st.st_mode & S_IFMT != S_IFDIR || st.st_uid != getuid() || access(path, W_OK) != 0 {
            return "The app is not writable by this user; use its original updater"
        }
        if AppUninstaller.runningProcess(in: [path], processes: processes) != nil { return "Quit this app before updating it" }
        return nil
    }

    public static func prepare(_ reviewed: NativeUpdateCheck, archive: URL, home: String = NSHomeDirectory(),
                               reviewedArchiveSignature: String? = nil) throws -> PreparedNativeUpdate {
        try prepare(reviewed, archive: archive, home: home, reviewedArchiveSignature: reviewedArchiveSignature,
                    copyImage: NativeDiskImage.copyApplication)
    }

    static func prepare(_ reviewed: NativeUpdateCheck, archive: URL, home: String,
                        reviewedArchiveSignature: String? = nil, copyImage: (URL, String, String) throws -> Void) throws -> PreparedNativeUpdate {
        guard reviewed.status == "available", let release = reviewed.release, reviewed.source.canCheck,
              release.installationType == nil || release.installationType == "application",
              NativeAppUpdates.unchanged(reviewed.source), let id = reviewed.source.app.bundleID,
              !id.hasPrefix("com.apple."), !id.hasPrefix("dev.thermo."),
              !FS.exists(reviewed.source.app.path + "/Contents/_MASReceipt/receipt") else {
            throw failure("This update must be checked again or completed in its original updater")
        }
        if let why = targetRefusal(reviewed.source.app.path, home: home, processes: ProcessTable.current(.init(cpu: false))) { throw failure(why) }
        let old = try NativeBundleValidation.facts(reviewed.source.app.path)
        guard old.bundleID == id, old.build == reviewed.source.installedBuild,
              let info = AppMetadata.dictionary(reviewed.source.app.path + "/Contents/Info.plist"),
              let encodedKey = info["SUPublicEDKey"] as? String, let keyData = Data(base64Encoded: encodedKey), keyData.count == 32,
              let encodedSignature = release.signature, let signature = Data(base64Encoded: encodedSignature), signature.count == 64 else {
            throw failure("A valid embedded Ed25519 key and update signature are required")
        }
        let root = try storage(home)
        let workspace = root + "/" + UUID().uuidString
        try privateDirectory(workspace)
        guard let workspaceIdentity = FileIdentity.of(workspace) else { throw failure("The update workspace disappeared") }
        var keep = false
        defer { if !keep, FileIdentity.of(workspace) == workspaceIdentity { try? FileManager.default.removeItem(atPath: workspace) } }
        do {
            let payload = URL(fileURLWithPath: workspace + "/payload.archive")
            try FileManager.default.copyItem(at: archive, to: payload)
            var st = stat()
            guard lstat(payload.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size > 0, st.st_size <= 2 * 1024 * 1024 * 1024 else {
                throw failure("The update archive is unsafe or too large")
            }
            let data = try Data(contentsOf: payload, options: .mappedIfSafe)
            if let length = release.length, length != Int64(data.count) { throw failure("The update archive length differs from the feed") }
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
            guard key.isValidSignature(signature, for: data) else { throw failure("The update archive's Ed25519 signature is invalid") }
            if let reviewedArchiveSignature, reviewedArchiveSignature != encodedSignature {
                guard let previous = Data(base64Encoded: reviewedArchiveSignature), previous.count == 64,
                      key.isValidSignature(previous, for: data) else { throw failure("The downloaded archive differs from the reviewed signed archive") }
            }
            let unpacked = workspace + "/unpacked"
            try privateDirectory(unpacked)
            try Task.checkCancellation()
            if NativeDiskImage.isUDIF(data) {
                do { try copyImage(payload, workspace, unpacked) }
                catch let error as NativeDiskImage.CleanupFailure {
                    keep = true
                    throw preserveWorkspace(workspace, identity: workspaceIdentity, target: reviewed.source.app.path,
                                            reason: error.localizedDescription, home: home)
                }
            } else {
                let expanded = try NativeZipManifest.validate(payload)
                let free = (try FileManager.default.attributesOfFileSystem(forPath: workspace)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
                guard free > expanded * 2 + 16 * 1024 * 1024 else { throw failure("There is not enough space to prepare and preserve this update") }
                let extracted = CommandRunner.run("/usr/bin/tar", arguments: ["-x", "-f", payload.path, "-C", unpacked, "--no-same-owner", "--no-same-permissions", "--safe-writes"],
                                              timeout: 120, outputLimit: 1_048_576, captureError: false, cancelled: { Task.isCancelled })
                guard extracted.status == 0, !extracted.timedOut, !extracted.cancelled else { throw failure("The update could not be safely extracted") }
            }
            var bundles: [String] = []
            func find(_ directory: String, depth: Int) throws {
                for name in try FileManager.default.contentsOfDirectory(atPath: directory) where !name.hasPrefix(".") && name != "__MACOSX" {
                    let path = directory + "/" + name
                    var entry = stat()
                    guard lstat(path, &entry) == 0 else { throw failure("Cannot inspect the extracted update") }
                    if entry.st_mode & S_IFMT != S_IFDIR { continue }
                    if name.hasSuffix(".app") { bundles.append(path) }
                    else if depth < 1 { try find(path, depth: depth + 1) }
                }
            }
            try find(unpacked, depth: 0)
            guard bundles.count == 1, let bundle = bundles.first else { throw failure("The archive must contain exactly one application") }
            let new = try NativeBundleValidation.facts(bundle)
            try NativeBundleValidation.compatible(new, with: old, release: release)
            try NativeBundleValidation.publisherMatches(original: reviewed.source.app.path, replacement: bundle, team: old.team)
            if let minimum = new.minimumOS {
                let os = ProcessInfo.processInfo.operatingSystemVersion
                let order = UpdateVersion.compare("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", minimum)
                guard order == .orderedSame || order == .orderedDescending else {
                    throw failure("The downloaded app requires a newer or unrecognized macOS version")
                }
            }
            guard NativeAppUpdates.unchanged(reviewed.source) else { throw failure("The installed app changed while preparing the update") }
            guard FileIdentity.of(workspace) == workspaceIdentity else {
                keep = true
                throw preserveWorkspace(workspace, identity: workspaceIdentity, target: reviewed.source.app.path,
                                        reason: "The update workspace changed; it was preserved", home: home)
            }
            keep = true
            return PreparedNativeUpdate(source: reviewed.source, release: release, workspace: workspace, bundle: bundle, original: old, replacement: new, workspaceID: workspaceIdentity)
        } catch {
            if error is PreservedWorkspaceFailure { throw error }
            if FileIdentity.of(workspace) != workspaceIdentity {
                keep = true
                throw preserveWorkspace(workspace, identity: workspaceIdentity, target: reviewed.source.app.path,
                                        reason: "The update workspace changed; it was preserved", home: home)
            }
            throw error
        }
    }

    public static func discard(_ prepared: PreparedNativeUpdate, home: String = NSHomeDirectory()) throws {
        let root = try storage(home)
        guard (prepared.workspace as NSString).deletingLastPathComponent == root,
              UUID(uuidString: (prepared.workspace as NSString).lastPathComponent) != nil,
              FileIdentity.of(prepared.workspace) == prepared.workspaceID,
              URL(fileURLWithPath: prepared.workspace).resolvingSymlinksInPath().path == prepared.workspace else {
            throw failure("The update workspace changed; it was preserved")
        }
        try FileManager.default.removeItem(atPath: prepared.workspace)
    }

    final class TargetLock {
        let descriptor: Int32
        init(target: String, home: String) throws {
            let root = try storage(home)
            let fd = open(root + "/" + NativeAppUpdates.digest(target) + ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
            guard fd >= 0 else { throw failure("Cannot acquire the app update lock") }
            var keep = false
            defer { if !keep { close(fd) } }
            var st = stat()
            guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(), st.st_nlink == 1,
                  flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                throw failure("Another update owns this application, or its lock is unsafe")
            }
            descriptor = fd; keep = true
        }
        deinit { flock(descriptor, LOCK_UN); close(descriptor) }
    }

    private final class Parent {
        let path: String, identity: String, descriptor: Int32
        init(_ path: String) throws {
            guard URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path,
                  let identity = FileIdentity.of(path) else { throw failure("The app's parent directory changed") }
            let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw failure("Cannot open the app's parent directory") }
            var keep = false
            defer { if !keep { close(fd) } }
            var st = stat()
            guard fstat(fd, &st) == 0, "\(st.st_dev):\(st.st_ino)" == identity, FileIdentity.of(path) == identity else { throw failure("The app's parent directory changed") }
            self.path = path; self.identity = identity; descriptor = fd; keep = true
        }
        deinit { close(descriptor) }
        func entry(_ name: String) -> String? {
            var st = stat()
            guard fstatat(descriptor, name, &st, AT_SYMLINK_NOFOLLOW) == 0, st.st_mode & S_IFMT == S_IFDIR else { return nil }
            return "\(st.st_dev):\(st.st_ino)"
        }
        func matches() -> Bool {
            var st = stat()
            return fstat(descriptor, &st) == 0 && "\(st.st_dev):\(st.st_ino)" == identity && FileIdentity.of(path) == identity
                && URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path
        }
        func swap(_ a: String, _ b: String) throws {
            guard matches(), renameatx_np(descriptor, a, descriptor, b, UInt32(RENAME_SWAP)) == 0 else {
                throw failure("The atomic application swap failed")
            }
        }
    }

    static func save(_ receipt: NativeUpdateReceipt, home: String) throws {
        let root = try storage(home)
        guard UUID(uuidString: receipt.id) != nil else { throw failure("Invalid update receipt") }
        let url = URL(fileURLWithPath: root + "/" + receipt.id + ".json")
        if FS.exists(url.path) {
            var st = stat()
            guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(), st.st_nlink == 1 else { throw failure("The receipt was replaced") }
        }
        try JSONEncoder().encode(receipt).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func install(_ prepared: PreparedNativeUpdate, home: String = NSHomeDirectory()) -> NativeInstallResult {
        commit(prepared, home: home, processes: { ProcessTable.current(.init(cpu: false)) }, afterSwap: {})
    }

    static func commit(_ prepared: PreparedNativeUpdate, home: String, processes: () -> ProcessTable,
                       afterSwap: () throws -> Void) -> NativeInstallResult {
        var result = NativeInstallResult(outcome: "failed", message: "The native update was not installed")
        var receipt: NativeUpdateReceipt?
        let operationID = UUID().uuidString
        var adjacent: (Parent, String, String)?
        var swapped = false
        defer {
            if !swapped, let (parent, leaf, identity) = adjacent, parent.matches(), parent.entry(leaf) == identity {
                try? FileManager.default.removeItem(atPath: parent.path + "/" + leaf)
            }
            OperationJournal.record(OperationRecord(id: operationID, feature: "apps", action: "nativeUpdate", subject: prepared.source.app.name,
                outcome: result.outcome == "succeeded" ? "succeeded" : result.outcome == "unconfirmed" ? "partial" : "failed",
                items: [.init(target: prepared.source.app.path, status: result.outcome == "succeeded" ? "done" : result.outcome == "unconfirmed" ? "partial" : "failed", detail: result.message)],
                undo: receipt.map { .init(kind: "nativeUpdate", ref: $0.id) }), home: home)
        }
        do {
            _ = try storage(home)
            let lock = try TargetLock(target: prepared.source.app.path, home: home)
            defer { withExtendedLifetime(lock) {} }
            try Task.checkCancellation()
            if let why = targetRefusal(prepared.source.app.path, home: home, processes: processes()) { throw failure(why) }
            guard NativeAppUpdates.unchanged(prepared.source), try NativeBundleValidation.treeSeal(prepared.source.app.path) == prepared.original.seal,
                  try NativeBundleValidation.treeSeal(prepared.bundle) == prepared.replacement.seal else { throw failure("The app or prepared update changed after review") }
            let parent = try Parent((prepared.source.app.path as NSString).deletingLastPathComponent)
            let target = (prepared.source.app.path as NSString).lastPathComponent
            let leaf = ".thermo-update-" + operationID
            guard mkdirat(parent.descriptor, leaf, 0o700) == 0 else { throw failure("Cannot create a private adjacent update directory") }
            guard let directoryID = parent.entry(leaf) else { throw failure("The adjacent update directory changed") }
            adjacent = (parent, leaf, directoryID)
            let incoming = leaf + "/previous.app", absolute = parent.path + "/" + incoming
            try FileManager.default.copyItem(atPath: prepared.bundle, toPath: absolute)
            let copied = try NativeBundleValidation.facts(absolute)
            guard copied.seal == prepared.replacement.seal, parent.matches(), NativeAppUpdates.unchanged(prepared.source),
                  let originalID = parent.entry(target), let newID = parent.entry(incoming) else { throw failure("The app or prepared update changed after review") }
            if let why = targetRefusal(prepared.source.app.path, home: home, processes: processes()) { throw failure(why) }
            // Copying and the process inventory can take time. Metadata identity does
            // not cover resource edits below Contents; recheck both sealed trees after
            // that work, before creating a recovery record or displacing the target.
            guard parent.matches(), parent.entry(target) == originalID, parent.entry(incoming) == newID,
                  NativeAppUpdates.unchanged(prepared.source),
                  try NativeBundleValidation.treeSeal(prepared.source.app.path) == prepared.original.seal,
                  try NativeBundleValidation.treeSeal(absolute) == copied.seal,
                  parent.matches(), parent.entry(target) == originalID, parent.entry(incoming) == newID,
                  NativeAppUpdates.unchanged(prepared.source) else {
                throw failure("The app or prepared update changed after review")
            }
            var record = NativeUpdateReceipt(id: operationID, target: prepared.source.app.path, backup: absolute, phase: "prepared",
                original: prepared.original, replacement: copied, originalID: originalID, replacementID: newID)
            try save(record, home: home); receipt = record
            OperationJournal.record(OperationRecord(id: operationID, feature: "apps", action: "nativeUpdate", subject: prepared.source.app.name,
                outcome: "partial", items: [.init(target: record.target, status: "partial", detail: "The native update started; verification is pending")],
                undo: .init(kind: "nativeUpdate", ref: operationID)), home: home)
            try parent.swap(incoming, target)
            swapped = true
            do {
                try afterSwap()
                let installed = try NativeBundleValidation.facts(record.target)
                guard parent.matches(), parent.entry(target) == newID, parent.entry(incoming) == originalID,
                      installed.seal == copied.seal, try NativeBundleValidation.facts(record.backup).seal == prepared.original.seal else {
                    throw failure("The installed app or recovery copy did not pass final verification")
                }
                record.phase = "installed"; try save(record, home: home); receipt = record
                result.outcome = "succeeded"; result.message = "The native update was installed and verified; the previous app is preserved"
            } catch {
                if parent.matches(), parent.entry(target) == newID, parent.entry(incoming) == originalID,
                   AppUninstaller.runningProcess(in: [record.target, record.backup], processes: processes()) == nil,
                   (try? NativeBundleValidation.facts(record.backup).seal) == prepared.original.seal {
                    do {
                        try parent.swap(incoming, target)
                        guard try NativeBundleValidation.facts(record.target).seal == prepared.original.seal else { throw failure("Rollback verification failed") }
                        record.phase = "rolledBack"; try save(record, home: home); receipt = record
                        result.message = "Update verification failed; the original app was restored"
                    } catch {
                        record.phase = "unconfirmed"; try? save(record, home: home); receipt = record
                        result.outcome = "unconfirmed"; result.message = "The update could not be verified or rolled back; preserve the recovery record"
                    }
                } else {
                    record.phase = "unconfirmed"; try? save(record, home: home); receipt = record
                    result.outcome = "unconfirmed"; result.message = "The app or recovery copy changed after replacement; both were preserved without overwriting"
                }
            }
        } catch { result.message = error.localizedDescription }
        result.receipt = receipt
        return result
    }

    public static func receipts(home: String = NSHomeDirectory()) -> [NativeUpdateReceipt] {
        recovery(home: home).records
    }

    public static func recovery(home: String = NSHomeDirectory()) -> NativeRecoveryReport {
        var report = NativeRecoveryReport()
        let path = home + "/Library/Application Support/Thermo/app-updates"
        var st = stat()
        if lstat(path, &st) != 0, errno == ENOENT { return report }
        do {
            let root = try storage(home, create: false)
            for file in try FileManager.default.contentsOfDirectory(atPath: root).sorted() where file.hasSuffix(".json") {
                if file.hasPrefix("workspace-") {
                    do {
                        let workspace = try loadPreservedWorkspace(String(file.dropFirst("workspace-".count).dropLast(5)), home: home)
                        report.workspaces = (report.workspaces ?? []) + [workspace]
                        if (try? preservedWorkspaceURL(workspace, home: home)) == nil {
                            report.issues.append("A preserved update workspace is missing or changed; inspect the recorded path manually")
                        }
                    } catch { report.issues.append("A preserved update workspace record could not be safely read") }
                    continue
                }
                do {
                    let record = try load(String(file.dropLast(5)), home: home)
                    report.records.append(record)
                    report.backups = (report.backups ?? []) + [backupUsage(record, home: home)]
                }
                catch { report.issues.append("A native recovery record could not be safely read; preserve the recovery folder") }
            }
        } catch { report.issues.append("Native recovery storage could not be safely read; do not discard the application backups") }
        report.issues = Array(Set(report.issues)).sorted()
        return report
    }

    static func load(_ id: String, home: String) throws -> NativeUpdateReceipt {
        guard UUID(uuidString: id) != nil else { throw failure("Invalid update receipt") }
        let data = try recoveryData(id + ".json", home: home)
        let receipt = try JSONDecoder().decode(NativeUpdateReceipt.self, from: data)
        let parent = (receipt.target as NSString).deletingLastPathComponent
        guard receipt.id == id, receipt.backup == parent + "/.thermo-update-" + id + "/previous.app" else { throw failure("The recovery path is invalid") }
        return receipt
    }

    public static func restore(_ id: String, home: String = NSHomeDirectory(), review: NativeUpdateReceipt? = nil) -> NativeInstallResult {
        recover(id, home: home, review: review, processes: { ProcessTable.current(.init(cpu: false)) })
    }

    static func recover(_ id: String, home: String, review: NativeUpdateReceipt? = nil, processes: () -> ProcessTable) -> NativeInstallResult {
        var result = NativeInstallResult(outcome: "failed", message: "The previous app was not restored")
        defer {
            OperationJournal.record(OperationRecord(feature: "apps", action: "nativeRestore", subject: result.receipt?.target,
                outcome: result.outcome == "succeeded" ? "succeeded" : result.outcome == "unconfirmed" ? "partial" : "failed",
                items: [.init(target: id, status: result.outcome == "succeeded" ? "done" : result.outcome == "unconfirmed" ? "partial" : "failed", detail: result.message)]), home: home)
        }
        do {
            var record = try load(id, home: home)
            let expected = review ?? record
            func checkReview() throws {
                guard record == expected, try load(id, home: home) == expected else {
                    throw failure("Native update recovery record changed. Refresh recovery and review it again.")
                }
            }
            try checkReview()
            result.receipt = record
            let lock = try TargetLock(target: record.target, home: home)
            defer { withExtendedLifetime(lock) {} }
            try checkReview()
            if let why = targetRefusal(record.target, home: home, processes: processes()) { throw failure(why) }
            guard AppUninstaller.runningProcess(in: [record.backup], processes: processes()) == nil else { throw failure("Quit the preserved app before recovery") }
            let parent = try Parent((record.target as NSString).deletingLastPathComponent)
            let name = (record.target as NSString).lastPathComponent
            let backup = ".thermo-update-" + record.id + "/previous.app"
            if parent.entry(name) == record.originalID,
               try NativeBundleValidation.facts(record.target).seal == record.original.seal {
                try checkReview()
                record.phase = "restored"; try save(record, home: home)
                result.outcome = "succeeded"; result.message = "The original application is already in place"; result.receipt = record
                return result
            }
            guard parent.entry(name) == record.replacementID, parent.entry(backup) == record.originalID,
                  try NativeBundleValidation.facts(record.target).seal == record.replacement.seal,
                  try NativeBundleValidation.facts(record.backup).seal == record.original.seal else {
                throw failure("The installed or preserved app changed; recovery will not overwrite it")
            }
            try checkReview()
            record.phase = "restoring"; try save(record, home: home)
            try parent.swap(backup, name)
            do {
                guard parent.entry(name) == record.originalID, try NativeBundleValidation.facts(record.target).seal == record.original.seal else { throw failure("Recovery verification failed") }
                record.phase = "restored"; try save(record, home: home)
                result.outcome = "succeeded"; result.message = "The previous app was restored and verified; the newer copy was preserved"
            } catch {
                record.phase = "unconfirmed"; try? save(record, home: home)
                result.outcome = "unconfirmed"; result.message = "Recovery could not be confirmed; preserve both application copies"
            }
            result.receipt = record
        } catch { result.message = error.localizedDescription }
        return result
    }
}
