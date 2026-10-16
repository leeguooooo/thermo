import AgentCore
import Darwin
import Foundation

public struct NativeBackupRemovalReview: Codable, Sendable, Identifiable, Equatable {
    public var id: String { receipt.id }
    public var receipt: NativeUpdateReceipt
    public var backupVersion: String { backupFacts.version }
    public var currentVersion: String { targetFacts.version }
    public var allocatedBytes: Int64
    public var sizeComplete: Bool
    var backupFacts: NativeBundleFacts
    var targetFacts: NativeBundleFacts
    var backupIdentity: String
    var backupRootIdentity: String
    var targetIdentity: String
    var parentIdentity: String
}

extension NativeUpdateTransaction {
    public static func reviewBackupRemoval(_ receipt: NativeUpdateReceipt, home: String = NSHomeDirectory()) throws -> NativeBackupRemovalReview {
        try reviewBackupRemoval(receipt, home: home, processes: ProcessTable.current(.init(cpu: false)))
    }

    static func reviewBackupRemoval(_ receipt: NativeUpdateReceipt, home: String, processes: ProcessTable) throws -> NativeBackupRemovalReview {
        guard ["installed", "restored", "rolledBack"].contains(receipt.phase) else {
            throw failure("This update is not confirmed; preserve its backup for manual recovery")
        }
        let path = try backupURL(receipt, home: home).path
        if let why = Guard(home: home).uninstallRefusal(path, bundleIDs: []) { throw failure(why) }
        if let why = Guard(home: home).uninstallRefusal(receipt.target, bundleIDs: []) { throw failure(why) }
        let whitelist = try Whitelist.loadForRemoval(home: home)
        guard !whitelist.protects(path) else { throw failure("This backup is protected by the cleanup whitelist") }
        guard processes.available else { throw failure("Could not verify processes using this backup; keep it") }
        guard AppUninstaller.runningProcess(in: [path], processes: processes) == nil else { throw failure("Quit the preserved app before recovery") }
        let parent = (path as NSString).deletingLastPathComponent
        var info = stat()
        guard lstat(parent, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              let parentID = FileIdentity.of(parent), let backupID = ManualRemoval.reviewIdentity(path),
              let targetID = ManualRemoval.reviewIdentity(receipt.target) else { throw failure("The backup or current app changed; review backup removal again") }
        guard let rootID = FileIdentity.of(path), FileIdentity.of(receipt.target) != rootID else {
            throw failure("The current app does not match this backup; keep the recovery copy")
        }
        let backup = try NativeBundleValidation.facts(path)
        let expected = FileIdentity.of(path) == receipt.originalID ? receipt.original : receipt.replacement
        guard backup.seal == expected.seal, backup.bundleID == expected.bundleID,
              backup.build == expected.build, backup.team == expected.team else { throw failure("The preserved app changed; it was kept") }
        let target = try NativeBundleValidation.facts(receipt.target)
        guard target.bundleID == backup.bundleID, target.team == backup.team else {
            throw failure("The current app does not match this backup; keep the recovery copy")
        }
        let size = FS.discoverySize(path)
        guard try backupURL(receipt, home: home).path == path,
              ManualRemoval.reviewIdentity(path) == backupID, ManualRemoval.reviewIdentity(receipt.target) == targetID,
              FileIdentity.of(parent) == parentID else { throw failure("The backup or current app changed; review backup removal again") }
        return .init(receipt: receipt, allocatedBytes: size.allocated, sizeComplete: !size.incomplete && !size.denied,
                     backupFacts: backup, targetFacts: target, backupIdentity: backupID, backupRootIdentity: rootID, targetIdentity: targetID, parentIdentity: parentID)
    }

    public static func trashBackup(_ review: NativeBackupRemovalReview, home: String = NSHomeDirectory()) -> CleanResult {
        trashBackup(review, home: home, processes: { ProcessTable.current(.init(cpu: false)) }, openFiles: { OpenFiles.current() }, move: RemovalOperations.live.trash)
    }

    static func trashBackup(_ review: NativeBackupRemovalReview, home: String, processes: () -> ProcessTable,
                            openFiles: () -> OpenFiles?, move: (String) throws -> URL) -> CleanResult {
        let path = review.receipt.backup
        var result = CleanResult(id: "native-backup/" + review.id, trashed: true)
        defer {
            OperationJournal.record(OperationRecord(feature: "apps", action: "nativeBackupTrash", subject: path,
                outcome: result.failed.isEmpty ? "succeeded" : result.removed.isEmpty ? "failed" : "partial",
                items: [.init(target: path, status: result.removed.isEmpty ? "failed" : result.failed.isEmpty ? "done" : "partial",
                              detail: result.failed.values.sorted().joined(separator: "\n"))],
                undo: result.trashBatchID.map { .init(kind: "trashBatch", ref: $0) }
                    ?? (!result.removed.isEmpty ? .init(kind: "trash", ref: "") : nil)), home: home)
        }
        do {
            let lock = try TargetLock(target: review.receipt.target, home: home)
            defer { withExtendedLifetime(lock) {} }
            guard try reviewBackupRemoval(review.receipt, home: home, processes: processes()) == review else {
                throw failure("The backup or current app changed; review backup removal again")
            }
            guard let open = openFiles() else { throw failure("Could not verify processes using this backup; keep it") }
            guard open.holder(of: path) == nil else { throw failure("The preserved app is in use; keep it") }
            // Recheck after potentially slow process enumeration, immediately before the move.
            guard try reviewBackupRemoval(review.receipt, home: home, processes: processes()) == review else {
                throw failure("The backup or current app changed; review backup removal again")
            }
            guard try !Whitelist.loadForRemoval(home: home).protects(path) else { throw failure("This backup is protected by the cleanup whitelist") }
            guard try load(review.id, home: home) == review.receipt,
                  ManualRemoval.reviewIdentity(path) == review.backupIdentity,
                  ManualRemoval.reviewIdentity(review.receipt.target) == review.targetIdentity else {
                throw failure("The backup or current app changed; review backup removal again")
            }
            let destination = try move(path)
            result.removed = [path]; result.bytesIncomplete = true
            let batch = UUID().uuidString
            guard let identity = FileIdentity.of(destination.path) else {
                throw failure("The backup was moved, but its Trash identity is unknown; inspect the Trash manually")
            }
            do {
                try TrashBatches.append(.init(original: path, destination: destination.path, identity: identity, bytes: 0), id: batch, home: home)
                result.trashBatchID = batch
                try TrashBatches.synchronize(batch, home: home)
            } catch { result.failed["batch/" + path] = "moved to " + destination.path + ", but batch recording failed: " + error.localizedDescription }
            if identity != review.backupRootIdentity {
                result.failed[path] = "The moved backup identity changed; inspect the recorded Trash item"
            } else { result.trashedAllocatedBytes = review.allocatedBytes }
        } catch { result.failed[path] = error.localizedDescription }
        if !result.removed.isEmpty {
            ScanReportCache.invalidate(home: home); SpaceOverview.invalidate(home: home)
            if !SpaceLens.invalidateCache(at: SpaceLens.cacheURL(home: home)) {
                result.failed["cache"] = "The old space cache could not be cleared; scan again before using saved results"
            }
        }
        result.outcome = result.failed.isEmpty ? "success" : result.removed.isEmpty ? "failed" : "partial"
        return result
    }
}
