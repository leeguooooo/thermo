import XCTest
import CleanKit
import ThermoL10n
@testable import ThermoApp

final class DiskScanSummaryTests: XCTestCase {
    override func tearDown() { L10n.override = nil }
    func report(_ items: [CleanItem] = [], cancelled: Bool = false) -> ScanReport {
        .init(items: items, denied: [], started: Date(), duration: 1, cancelled: cancelled)
    }
    func item(_ bytes: Int64 = 100) -> CleanItem {
        .init(id: "fixture", category: .devCaches, title: "Fixture", safety: .safe,
              bytes: bytes, paths: ["/fixture/cache"])
    }
    func testStoppedScansNeverShowCompleteEmptyOrReclaimableSuccess() {
        L10n.override = .english
        for items in [[], [item()]] {
            let summary = DiskScanSummary(report(items, cancelled: true), safeBytes: 0)
            XCTAssertEqual(summary.status, .stopped)
            XCTAssertEqual(summary.title, "Scan stopped")
            XCTAssertNotEqual(summary.symbol, "checkmark")
            XCTAssertTrue(summary.subtitle.contains("remaining locations"))
        }
    }
    func testUnreadableLocationsRulesAndSizesCannotCertifyEmptyScan() {
        L10n.override = .english
        var denied = report(); denied.denied = ["/fixture/unreadable"]
        var rules = report(); rules.whitelistError = "fixture read failure"
        var unknown = item(0); unknown.sizeIncomplete = true
        var estimated = item(0); estimated.estimatedSize = true
        for value in [denied, rules, report([unknown]), report([estimated])] {
            let summary = DiskScanSummary(value, safeBytes: 0)
            XCTAssertEqual(summary.status, .incomplete)
            XCTAssertEqual(summary.title, "Scan incomplete")
            XCTAssertNotEqual(summary.symbol, "checkmark")
        }
    }
    func testBlockedFindingsAreKeptRatherThanReportedAsNothing() {
        L10n.override = .english
        var blocked = item(); blocked.blocked = "fixture process still running"
        let summary = DiskScanSummary(report([blocked]), safeBytes: 0)
        XCTAssertEqual(summary.status, .kept)
        XCTAssertEqual(summary.title, "Items were kept")
    }
    func testOnlyConfirmedEmptyReportUsesTheAllClear() {
        L10n.override = .english
        let empty = DiskScanSummary(report(), safeBytes: 0)
        XCTAssertEqual(empty.status, .empty); XCTAssertEqual(empty.symbol, "checkmark")
        XCTAssertEqual(empty.title, "Nothing to clean.")
        XCTAssertEqual(DiskScanSummary(report([item(0)]), safeBytes: 0).status, .review)
        XCTAssertEqual(DiskScanSummary(report([item()]), safeBytes: 100).status, .found)
    }
    @MainActor func testChineseBackendProgressAndPartialHeadlineAreLocalized() {
        L10n.override = .simplifiedChinese
        XCTAssertEqual(DiskModel.progressTitle("reading processes"), "正在读取进程…")
        XCTAssertEqual(DiskModel.progressTitle("space context"), "正在读取磁盘信息…")
        XCTAssertEqual(DiskModel.progressTitle("projects"), "项目")
        XCTAssertEqual(DiskModel.progressTitle("/fixture/custom"), "/fixture/custom")
        XCTAssertEqual(DiskScanSummary(report(cancelled: true), safeBytes: 0).title, "扫描已停止")
    }
}
