import Foundation
import Darwin

/// Allocated usage of a recovery copy, not a promise of space deletion would free.
public struct NativeBackupUsage: Codable, Sendable, Identifiable {
    public var id: String
    public var path: String
    public var allocatedBytes: Int64?
    public var files: Int?
    public var complete: Bool
    public var issue: String?

    public init(id: String, path: String, allocatedBytes: Int64? = nil, files: Int? = nil, complete: Bool = false, issue: String? = nil) {
        self.id = id; self.path = path; self.allocatedBytes = allocatedBytes
        self.files = files; self.complete = complete; self.issue = issue
    }
}

extension NativeUpdateTransaction {
    /// Validate the recorded location before revealing it; never launch the backup app.
    public static func backupURL(_ reviewed: NativeUpdateReceipt, home: String = NSHomeDirectory()) throws -> URL {
        guard try load(reviewed.id, home: home) == reviewed else {
            throw failure("Native update recovery record changed. Refresh recovery and review it again.")
        }
        let url = URL(fileURLWithPath: reviewed.backup)
        var presence = stat()
        if lstat(reviewed.backup, &presence) != 0, errno == ENOENT {
            throw failure("The recovery copy is not at its recorded path. If it was moved to the Trash, restore it from History first.")
        }
        guard url.resolvingSymlinksInPath().path == reviewed.backup,
              FS.isDirectory(reviewed.backup), let identity = FileIdentity.of(reviewed.backup),
              identity == reviewed.originalID || identity == reviewed.replacementID else {
            throw failure("The preserved app is missing or changed; refresh recovery before inspecting it")
        }
        guard try load(reviewed.id, home: home) == reviewed else {
            throw failure("Native update recovery record changed. Refresh recovery and review it again.")
        }
        return url
    }

    static func backupUsage(_ record: NativeUpdateReceipt, home: String) -> NativeBackupUsage {
        var usage = NativeBackupUsage(id: record.id, path: record.backup, complete: false)
        do {
            let url = try backupURL(record, home: home)
            let before = AppDataReviewIdentity.of(url.path)
            let size = FS.discoverySize(url.path)
            guard before != nil, before == AppDataReviewIdentity.of(url.path),
                  try backupURL(record, home: home) == url else {
                throw failure("The preserved app changed while measuring it; refresh recovery")
            }
            if size.incomplete && size.files == 0 {
                usage.issue = "Preserved app size could not be measured"
                return usage
            }
            usage.allocatedBytes = size.allocated; usage.files = size.files
            usage.complete = !size.incomplete && !size.denied
            if !usage.complete { usage.issue = "Preserved app size is incomplete; the shown usage is a lower bound" }
        } catch { usage.issue = error.localizedDescription }
        return usage
    }
}
