// Ported from YunX-Desktop (MIT): data/repository/TransferSpaceGuard.kt.
import Foundation

/// Fails a save early when it cannot fit, so a stuck task is not misreported as a timeout.
/// Unknown sizes and failed quota lookups pass.
public enum SpaceGuard {
    public static func ensureEnoughSpace(required: Int64?, quota: () async -> DriveQuota?) async throws {
        guard let required, required > 0 else { return }
        guard let info = await quota(), info.total > 0 else { return }
        let free = info.total - info.used
        if required > free { throw DriveError.insufficientSpace(required: required, available: free) }
    }

    /// Checks a batch with one quota lookup. Returns true when per-file checks can be skipped.
    public static func ensureEnoughSpaceForBatch(sizes: [Int64], quota: () async -> DriveQuota?) async throws -> Bool {
        if sizes.contains(where: { $0 <= 0 }) { return false }
        let required = sizes.reduce(0, +)
        if required <= 0 { return false }
        guard let info = await quota(), info.total > 0 else { return true }
        let free = info.total - info.used
        if required > free { throw DriveError.insufficientSpace(required: required, available: free) }
        return true
    }

    public static func formatBytes(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0 ? "\(bytes) B" : String(format: "%.1f %@", value, units[unit])
    }
}
