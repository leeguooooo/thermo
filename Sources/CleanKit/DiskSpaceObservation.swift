import Darwin
import Foundation

/// A cheap live filesystem measurement, excluding space macOS might purge later.
public struct DiskSpaceSnapshot: Codable, Sendable, Equatable {
    public var volumeID: String
    public var capacityBytes: Int64
    public var availableBytes: Int64
    public var measuredAt: Date

    public init(volumeID: String, capacityBytes: Int64, availableBytes: Int64, measuredAt: Date) {
        self.volumeID = volumeID; self.capacityBytes = capacityBytes
        self.availableBytes = availableBytes; self.measuredAt = measuredAt
    }

    public static func measure(path: String = NSHomeDirectory()) -> Self? {
        var fs = statfs()
        guard statfs(path, &fs) == 0, let blocks = Int64(exactly: fs.f_blocks),
              let available = Int64(exactly: fs.f_bavail) else { return nil }
        let capacity = blocks.multipliedReportingOverflow(by: Int64(fs.f_bsize))
        let free = available.multipliedReportingOverflow(by: Int64(fs.f_bsize))
        guard !capacity.overflow, !free.overflow, capacity.partialValue > 0,
              free.partialValue >= 0, free.partialValue <= capacity.partialValue else { return nil }
        return Self(volumeID: "\(fs.f_fsid.val.0):\(fs.f_fsid.val.1)", capacityBytes: capacity.partialValue,
                    availableBytes: free.partialValue, measuredAt: Date())
    }
}

/// The filesystem change during an operation, including concurrent disk activity.
/// It must not be attributed entirely to the files this operation removed.
public struct DiskSpaceObservation: Codable, Sendable, Equatable {
    public var before: DiskSpaceSnapshot?
    public var after: DiskSpaceSnapshot?
    public var availableChangeBytes: Int64?

    public init(before: DiskSpaceSnapshot?, after: DiskSpaceSnapshot?) {
        self.before = before; self.after = after
        if let before, let after, before.volumeID == after.volumeID, after.measuredAt >= before.measuredAt,
           before.availableBytes >= 0, after.availableBytes >= 0 {
            availableChangeBytes = after.availableBytes - before.availableBytes
        } else { availableChangeBytes = nil }
    }

    public var summary: String {
        guard let before, let after, let delta = availableChangeBytes else {
            return tr("Disk free space could not be verified")
        }
        let change: String
        if delta > 0 { change = tr("increased by %1$@", ByteFormat.string(delta)) }
        else if delta < 0 { change = tr("decreased by %1$@", ByteFormat.string(-delta)) }
        else { change = tr("no increase") }
        return tr("Disk free space: %1$@ → %2$@ (%3$@)", ByteFormat.string(before.availableBytes), ByteFormat.string(after.availableBytes), change)
            + "\n" + tr("Measured before and after; includes other disk activity.")
    }
}
