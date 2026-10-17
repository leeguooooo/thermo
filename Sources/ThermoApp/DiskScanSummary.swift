import CleanKit
import SwiftUI
import ThermoL10n

/// A zero byte count alone cannot certify that a scan completed or found nothing.
struct DiskScanSummary {
    enum Status: Equatable { case stopped, incomplete, kept, found, empty, review }
    let status: Status
    let title: String
    let subtitle: String
    var symbol: String {
        switch status {
        case .stopped: return "pause.circle"
        case .incomplete: return "exclamationmark.triangle"
        case .kept: return "shield"
        case .empty: return "checkmark"
        case .found, .review: return "internaldrive.fill"
        }
    }
    var color: Color {
        switch status {
        case .stopped, .incomplete: return .orange
        case .kept, .review: return .blue
        case .empty: return .green
        case .found: return .pink
        }
    }
    init(_ report: ScanReport, safeBytes: Int64) {
        let estimated = report.items.contains { $0.estimatedSize == true || $0.sizeIncomplete == true }
        if report.cancelled {
            status = .stopped; title = tr("Scan stopped")
            subtitle = tr("Results found so far are shown. Scan again to check the remaining locations.")
        } else if !report.denied.isEmpty || report.whitelistError != nil || report.items.contains(where: { $0.sizeIncomplete == true }) || (report.totalBytes == 0 && estimated) {
            status = .incomplete; title = tr("Scan incomplete")
            subtitle = tr("Some locations or sizes could not be checked. Review the available results or scan again.")
        } else if report.totalBytes > 0 {
            status = .found
            title = estimated ? tr("%1$@ in measured files (estimated)", ByteFormat.string(report.totalBytes)) : tr("%1$@ can be freed", ByteFormat.string(report.totalBytes))
            subtitle = tr("%1$@ selected by default. Development dependencies are kept; other items need your review.", ByteFormat.string(safeBytes))
        } else if report.items.isEmpty {
            status = .empty; title = tr("Nothing to clean.")
            subtitle = tr("%1$@ selected by default. Development dependencies are kept; other items need your review.", ByteFormat.string(safeBytes))
        } else if report.items.contains(where: { $0.blocked != nil }) {
            status = .kept; title = tr("Items were kept")
            subtitle = tr("Items were found but are kept in their current state. Review their reasons.")
        } else {
            status = .review; title = tr("Review scan results")
            subtitle = tr("Review the discovered items and their reasons before choosing what to clean.")
        }
    }
}
