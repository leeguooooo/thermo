@testable import CleanKit
@testable import ThermoApp
import XCTest

final class AppUpdatesModelTests: XCTestCase {
    @MainActor
    func testConfirmedInstallationContinuesAfterPageRetiresAndStaysBusyUntilVerified() async throws {
        let began = expectation(description: "installer running")
        let verified = expectation(description: "verification finished")
        let release = DispatchSemaphore(value: 0)
        let item = AppUpdate(token: "fixture", name: "Fixture", installedVersions: ["1"], targetVersion: "2",
            appPaths: ["/fixture.app"], bundleIDs: [:], identities: [:], definition: "fixture", brew: "/fixture", brewIdentity: "fixture")
        let model = AppUpdatesModel(read: { refreshCatalog in
            XCTAssertFalse(refreshCatalog, "installation readback must not refresh the catalog")
            verified.fulfill()
            return AppUpdateReport()
        }, install: { plan in
            XCTAssertEqual(plan.token, "fixture")
            began.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            return AppUpdateResult(token: plan.token, outcome: "succeeded", message: "fixture verified")
        })
        model.apply(item)
        await fulfillment(of: [began], timeout: 5)
        model.retire()
        XCTAssertTrue(model.working)
        model.refresh(catalog: true)
        XCTAssertNil(model.report)
        release.signal()
        await fulfillment(of: [verified], timeout: 5)
        for _ in 0..<100 where model.working { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.working)
        XCTAssertEqual(model.result?.outcome, "succeeded")
    }
}
