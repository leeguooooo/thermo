import XCTest
@testable import CleanKit
@testable import ThermoApp

final class HistoryRestoreInvalidationTests: XCTestCase {
    @MainActor func testRestoreInvalidationClearsOldOutcomeAndCancelsAStaleReview() async {
        let began = expectation(description: "review starts")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let model = AppsModel(reviewPlan: { app, _, _, _ in
            began.fulfill(); _ = release.wait(timeout: .now() + 5)
            return UninstallPlan(app: app, paths: [], bytes: 0)
        })
        model.outcome = "old removal result"
        model.review(InstalledApp(path: "/fixture.app", name: "Fixture", bundleID: "com.example.fixture"))
        await fulfillment(of: [began], timeout: 2)
        model.invalidateAfterRestore()
        XCTAssertNil(model.outcome); XCTAssertNil(model.plan)
        release.signal()
        for _ in 0..<100 where model.planning != nil { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(model.planning); XCTAssertNil(model.plan)
    }
}
