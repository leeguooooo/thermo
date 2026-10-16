import XCTest
@testable import CleanKit

final class ScopedScanCacheTests: XCTestCase {
    var home = ""
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: home) }
    func report(_ category: CleanCategory, at time: TimeInterval, roots: [String] = ["/project"]) -> ScanReport {
        var r = ScanReport(items: [.init(id: category.rawValue, category: category, title: "fixture", safety: .review,
                                        bytes: 10, paths: ["/fixture"])], denied: [], started: Date(timeIntervalSince1970: time), duration: 1)
        r.categories = [category]; r.olderThanDays = 30; r.language = "en"
        r.projectRoots = roots; r.discoverProjectRoots = false
        return r
    }
    func testCategoryScansKeepSeparateDatesAndPlans() throws {
        ScanReportCache.save(report(.xcode, at: 100), home: home)
        ScanReportCache.save(report(.aiModels, at: 200), home: home)
        let now = Date(timeIntervalSince1970: 250)
        let xcode = try XCTUnwrap(ScanReportCache.load(home: home, maxAge: 200, now: now, matching: { $0.categories == [.xcode] }))
        XCTAssertEqual(xcode.started, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(xcode.items.map(\.id), [CleanCategory.xcode.rawValue])
        XCTAssertEqual(ScanReportCache.load(home: home, maxAge: 200, now: now)?.categories, [.aiModels])
        XCTAssertNil(ScanReportCache.load(home: home, maxAge: 100, now: now, matching: { $0.categories == [.xcode] }),
                     "new model scan cannot make the Xcode scan fresh again")
    }
    func testDifferentRootsRemainSeparateAndInvalidationClearsEveryPlan() throws {
        ScanReportCache.save(report(.projects, at: 100, roots: ["/one"]), home: home)
        ScanReportCache.save(report(.projects, at: 200, roots: ["/two"]), home: home)
        let now = Date(timeIntervalSince1970: 250)
        XCTAssertNotNil(ScanReportCache.load(home: home, maxAge: 200, now: now, matching: { $0.projectRoots == ["/one"] }))
        XCTAssertNotNil(ScanReportCache.load(home: home, maxAge: 200, now: now, matching: { $0.projectRoots == ["/two"] }))
        ScanReportCache.invalidate(home: home)
        XCTAssertNil(ScanReportCache.load(home: home, maxAge: 200, now: now))
    }
    func testCancelledScanCannotReplaceScopedPlanAndOlderWriteCannotRenewIt() throws {
        ScanReportCache.save(report(.projects, at: 200), home: home)
        var cancelled = report(.projects, at: 300); cancelled.cancelled = true
        ScanReportCache.save(cancelled, home: home)
        ScanReportCache.save(report(.projects, at: 100), home: home)
        let saved = try XCTUnwrap(ScanReportCache.load(home: home, maxAge: 200, now: Date(timeIntervalSince1970: 250)))
        XCTAssertEqual(saved.started, Date(timeIntervalSince1970: 200))
    }
}

extension ScopedScanCacheTests {
    func testKeepAllAndDifferentConversationAgesHaveSeparateCachedPlans() throws {
        let choices: [Int?] = [nil,30,90]
        for (index,days) in choices.enumerated() {
            var r = report(.aiSessions,at:100+Double(index));r.sessionPolicyVersion = ScanOptions.sessionPolicyVersion;r.sessionRetentionDays = days
            ScanReportCache.save(r,home:home)
        }
        for days in choices {
            let cached = ScanReportCache.load(home:home,maxAge:200,now:Date(timeIntervalSince1970:250),matching:{ $0.sessionRetentionDays == days && $0.sessionPolicyVersion == ScanOptions.sessionPolicyVersion })
            XCTAssertNotNil(cached)
            XCTAssertEqual(cached?.sessionRetentionDays,days)
        }
    }
    func testConversationPolicyChangeCannotLookLikeFilesWereCleaned() {
        var before = report(.aiSessions,at:100);before.sessionRetentionDays = 30;before.sessionPolicyVersion = ScanOptions.sessionPolicyVersion
        var after = before;after.started = Date(timeIntervalSince1970:200);after.items[0].bytes = 5
        XCTAssertNotNil(CleanScanHistory.compare(after,with:before))
        after.sessionRetentionDays = nil
        XCTAssertNil(CleanScanHistory.compare(after,with:before))
        after.sessionRetentionDays = 30;after.sessionPolicyVersion = nil
        XCTAssertNil(CleanScanHistory.compare(after,with:before))
    }
}
