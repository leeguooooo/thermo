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
    /// One row's own clean button: independent of what is ticked.
    var single = false
    var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
}

extension DiskModel {
    func cleanupReview() -> DiskCleanupReview? {
        let items = selectedItems
        guard !cleaning, !items.isEmpty else { return nil }
        return .init(items: items, scannedAt: report?.started, lines: planLines,
                     summary: confirmSummary, destructive: confirmationIsDestructive)
    }
    /// Review just this row, narrowed to the parts still ticked.
    func cleanupReview(of item: CleanItem) -> DiskCleanupReview? {
        guard !cleaning, let current = singleTarget(item.id) else { return nil }
        return .init(items: [current], scannedAt: report?.started, lines: planLines(for: [current]),
                     summary: confirmSummary(for: [current]), destructive: confirmationIsDestructive(for: [current]), single: true)
    }
    private func singleTarget(_ id: String) -> CleanItem? {
        selectedItems.first { $0.id == id } ?? (report?.items ?? []).first { $0.id == id && isEligible($0) }
    }
    func isCurrentCleanupReview(_ review: DiskCleanupReview) -> Bool {
        guard !cleaning, review.scannedAt == report?.started else { return false }
        if review.single { return review.items.allSatisfy { $0 == singleTarget($0.id) } }
        // Findings keep arriving during a scan: what was reviewed must stand, not the whole list.
        if scanning { return review.items.allSatisfy { reviewed in selectedItems.contains { $0 == reviewed } } }
        return review.items == selectedItems
    }
}
