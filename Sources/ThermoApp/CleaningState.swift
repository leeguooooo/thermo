import CleanKit
import Foundation
import ThermoL10n

extension DiskModel {
    /// Called on the cleaning queue: remeasure what is left, including sessions the user kept.
    static func remainder(_ original: CleanItem, attempted: CleanItem, result: CleanResult,
                          size: (String) -> Int64? = { FS.exists($0) ? FS.size($0).bytes : nil }) -> CleanItem? {
        let retryReason = tr("Cleanup did not finish. Scan again to review the remaining items before retrying.")
        func requiringReview(_ item: CleanItem) -> CleanItem { var value = item; value.blocked = retryReason; return value }
        if !(original.commands ?? []).isEmpty {
            return result.failed.isEmpty ? nil : requiringReview(original)
        }
        if result.failed[original.id] != nil { return requiringReview(original) }
        let touched = Set(attempted.paths), removed = Set(result.removed)
        var needsReview = !result.failed.isEmpty
        func remainingSize(_ path: String, fallback: Int64) -> Int64? {
            // A completed move/removal belongs to the reviewed object, never a new file at its old path.
            if removed.contains(path) { return nil }
            if touched.contains(path) { needsReview = true }
            // nil is ambiguous (missing or unreadable), so retain unresolved paths until a new scan.
            return size(path) ?? fallback
        }
        var rest = original
        if let parts = original.parts {
            let remaining = parts.compactMap { part -> CleanPart? in
                guard part.paths.contains(where: touched.contains) else { return part }
                var part = part
                let paths = part.paths.compactMap { path in remainingSize(path, fallback: part.bytes / Int64(max(1, part.paths.count))).map { (path, $0) } }
                guard !paths.isEmpty else { return nil }
                part.paths = paths.map { $0.0 }
                part.bytes = paths.reduce(0) { $0 + $1.1 }
                return part
            }
            guard !remaining.isEmpty else { return nil }
            rest = original.only(Set(remaining.map(\.id)))
            rest.parts = remaining
            rest.paths = remaining.flatMap(\.paths)
            rest.bytes = remaining.reduce(0) { $0 + $1.bytes }
        } else {
            let paths = original.paths.compactMap { path in remainingSize(path, fallback: max(0, original.bytes - result.bytes) / Int64(max(1, original.paths.count))).map { (path, $0) } }
            guard !paths.isEmpty else { return nil }
            rest.paths = paths.map { $0.0 }
            rest.bytes = paths.reduce(0) { $0 + $1.1 }
        }
        return needsReview ? requiringReview(rest) : rest
    }
}
