import XCTest
import CleanKit
@testable import ThermoApp

final class CleaningStateTests: XCTestCase {
    func testCompletedScanReflectsItsActualScope() {
        let model = DiskModel()
        var report = ScanReport(items: [], denied: [], started: Date(), duration: 1)
        report.categories = CleanCategory.allCases.filter(\.isAI)
        model.acceptScan(report)
        XCTAssertTrue(model.stale, "An AI-only scan cannot be shown as a complete all-category scan")
        model.scope = .ai
        model.acceptScan(report)
        XCTAssertFalse(model.stale)
    }

    func testCompletingScanPreservesDeselectionAndSelectsNewSafeItems() {
        let first = CleanItem(id: "first", category: .devCaches, title: "First", safety: .safe, bytes: 10, paths: ["/fixture/first"])
        let next = CleanItem(id: "next", category: .devCaches, title: "Next", safety: .safe, bytes: 20, paths: ["/fixture/next"])
        let model = DiskModel(report: ScanReport(items: [first], denied: [], started: Date(), duration: 0))
        // The streamed item was manually unchecked before the scan finished.
        model.selected = []
        model.acceptScan(ScanReport(items: [first, next], denied: [], started: Date(), duration: 1))
        XCTAssertEqual(model.selected, ["next"])
    }

    func testPartialSessionCleanupKeepsUnselectedSession() {
        let remove = CleanPart(id: "remove", title: "Remove", bytes: 10, lastUsed: nil, paths: ["/fixture/remove"])
        let keep = CleanPart(id: "keep", title: "Keep", bytes: 20, lastUsed: nil, paths: ["/fixture/keep"])
        let item = CleanItem(id: "sessions", category: .aiSessions, title: "Codex · project · 2 sessions", safety: .review,
                             bytes: 30, paths: remove.paths + keep.paths, parts: [remove, keep])
        var result = CleanResult(id: item.id, trashed: true)
        result.removed = remove.paths
        result.bytes = 10
        let rest = DiskModel.remainder(item, attempted: item.only(["remove"]), result: result) { path in
            if path == "/fixture/keep" { XCTFail("An untouched session should not be remeasured") }
            return nil
        }
        XCTAssertEqual(rest?.paths, keep.paths)
        XCTAssertEqual(rest?.parts?.map(\.id), ["keep"])
        XCTAssertEqual(rest?.bytes, 20)
    }

    func testFailedPathsRemainAndRemovedPathsDisappear() {
        let item = CleanItem(id: "cache", category: .devCaches, title: "Cache", safety: .safe, bytes: 30,
                             paths: ["/fixture/removed", "/fixture/failed"])
        var result = CleanResult(id: item.id, trashed: false)
        result.removed = ["/fixture/removed"]
        result.failed = ["/fixture/failed": "modified since the scan"]
        result.bytes = 10
        let rest = DiskModel.remainder(item, attempted: item, result: result) { $0 == "/fixture/failed" ? 25 : nil }
        XCTAssertEqual(rest?.paths, ["/fixture/failed"])
        XCTAssertEqual(rest?.bytes, 25)
    }

    func testInaccessibleFailedPathIsNotReportedAsRemoved() {
        let item = CleanItem(id: "cache", category: .devCaches, title: "Cache", safety: .safe, bytes: 30, paths: ["/fixture/denied"])
        var result = CleanResult(id: item.id, trashed: false)
        result.failed = ["/fixture/denied": "permission denied"]
        let rest = DiskModel.remainder(item, attempted: item, result: result) { _ in nil }
        XCTAssertEqual(rest?.paths, item.paths)
        XCTAssertEqual(rest?.bytes, item.bytes)
    }

    func testFullyRemovedItemDisappears() {
        let item = CleanItem(id: "cache", category: .devCaches, title: "Cache", safety: .safe, bytes: 30, paths: ["/fixture/removed"])
        XCTAssertNil(DiskModel.remainder(item, attempted: item, result: CleanResult(id: item.id, trashed: false)) { _ in nil })
    }
}
