import CleanKit
import Foundation

/// One confirmation's displayed plan and execution inputs. No live model references.
struct DiskCleanupReview: Identifiable, Sendable {
    let id = UUID()
    let items: [CleanItem]
    let scannedAt: Date?
    let lines: [String]
    let summary: String
    let destructive: Bool
    var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
}

extension DiskModel {
    func cleanupReview() -> DiskCleanupReview? {
        let items = selectedItems
        guard !scanning, !cleaning, !items.isEmpty else { return nil }
        return .init(items: items, scannedAt: report?.started, lines: planLines,
                     summary: confirmSummary, destructive: confirmationIsDestructive)
    }
    func isCurrentCleanupReview(_ review: DiskCleanupReview) -> Bool {
        !scanning && !cleaning && review.items == selectedItems && review.scannedAt == report?.started
    }
}
