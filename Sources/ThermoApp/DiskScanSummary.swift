import CleanKit
import SwiftUI
import ThermoL10n

/// A zero byte count alone cannot certify that a scan completed or found nothing.
struct DiskScanSummary {
    typealias Status = ScanReport.ResultState
    let status: Status
    let title: String
    let subtitle: String
    var symbol: String {
        switch status {
        case .stopped: return "pause.circle"
        case .incomplete: return "exclamationmark.triangle"
        case .kept: return "shield"
        case .empty: return "checkmark"
        case .found, .review: return "internaldrive"
        }
    }
    var color: Color {
        switch status {
        case .stopped, .incomplete: return Theme.caution
        case .kept, .review: return Theme.accent
        case .empty: return Theme.good
        case .found: return Theme.accent
        }
    }
    init(_ report: ScanReport, safeBytes: Int64) {
        let estimated = report.items.contains { $0.estimatedSize == true || $0.sizeIncomplete == true }
        status = report.resultState
        switch status {
        case .stopped:
            title = tr("Scan stopped")
            subtitle = tr("Results found so far are shown. Scan again to check the remaining locations.")
        case .incomplete:
            title = tr("Scan incomplete")
            subtitle = tr("Some locations or sizes could not be checked. Review the available results or scan again.")
        case .found:
            title = estimated ? tr("%1$@ in measured files (estimated)", ByteFormat.string(report.totalBytes)) : tr("%1$@ can be freed", ByteFormat.string(report.totalBytes))
            subtitle = tr("%1$@ selected by default. Development dependencies are kept; other items need your review.", ByteFormat.string(safeBytes))
        case .empty:
            title = tr("Nothing to clean.")
            subtitle = tr("%1$@ selected by default. Development dependencies are kept; other items need your review.", ByteFormat.string(safeBytes))
        case .kept:
            title = tr("Items were kept")
            subtitle = tr("Items were found but are kept in their current state. Review their reasons.")
        case .review:
            title = tr("Review scan results")
            subtitle = tr("Review the discovered items and their reasons before choosing what to clean.")
        }
    }
}
