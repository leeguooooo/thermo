@testable import CleanKit
@testable import ThermoApp
import XCTest
import AppKit

final class AppsModelTests: XCTestCase {
    @MainActor
    func testConfirmedRemovalSurvivesWindowRetirementAndBlocksQuitWithoutOpeningARealWindow() async throws {
        let began = expectation(description: "removal running")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let model = AppsModel(remove: { _ in
            began.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            return CleanResult(id: "app-data:fixture", trashed: true)
        })
        let previous = AppModels.shared.apps
        AppModels.shared.apps = model
        defer { AppModels.shared.apps = previous }
        let app = InstalledApp(path: "/fixture.app", name: "Fixture", bundleID: "com.example.fixture")
        var plan = UninstallPlan(app: app, paths: [], bytes: 0); plan.removeApp = false
        model.uninstall(plan)
        await fulfillment(of: [began], timeout: 5)
        model.retire()
        model.uninstall(plan)
        model.load()
        XCTAssertFalse(model.loading)
        XCTAssertTrue(model.working)
        var pages: [MainPage] = []
        XCTAssertEqual(AppExitGuard.reply(show: { pages.append($0) }), .terminateCancel)
        XCTAssertEqual(pages, [.apps(.installed)])
        XCTAssertTrue(model.exitRequested)
        release.signal()
        for _ in 0..<100 where model.working { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.working)
        XCTAssertEqual(AppExitGuard.reply(show: { _ in XCTFail("completed work must allow quit") }), .terminateNow)
    }

    @MainActor
    func testRetirementCancelsReviewWithoutPublishingOrStartingAnOverlappingReview() async throws {
        let began = expectation(description: "review reading")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let model = AppsModel(reviewPlan: { app, _, removeApp, token in
            XCTAssertFalse(removeApp)
            began.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            XCTAssertTrue(token.isCancelled)
            var plan = UninstallPlan(app: app, paths: [], bytes: 0)
            plan.removeApp = removeApp
            return plan
        })
        let app = InstalledApp(path: "/fixture.app", name: "Fixture", bundleID: "com.example.fixture")
        model.review(app, removeApp: false)
        await fulfillment(of: [began], timeout: 5)
        model.retire()
        XCTAssertEqual(model.planning, app.path)
        model.review(app)
        release.signal()
        for _ in 0..<100 where model.planning != nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(model.planning)
        XCTAssertNil(model.plan)
    }

    @MainActor
    func testDataOnlyReviewKeepsBundleOutOfMoveLinesAndOmitsHomebrewUninstallAdvice() {
        var app = InstalledApp(path: "/Applications/Fixture.app", name: "Fixture", bundleID: "com.example.fixture")
        app.cask = "fixture"
        let data = AppLeftover(path: "/fixture/cache", bytes: 10, sizeState: .complete)
        app.leftovers = [data]
        var plan = UninstallPlan(app: app, paths: [data.path], bytes: 10)
        plan.removeApp = false
        plan.kept = [AppLeftover(path: "/fixture/personal", bytes: 10, personal: true)]
        plan.ownershipKept = ["/fixture/shared"]
        plan.ownership = AppOwnershipSnapshot(roots: ["/fixture"], extraPaths: [], issues: ["/fixture/unreadable"], fingerprint: "fixture")
        let lines = AppsPage.lines(plan)
        XCTAssertTrue(lines.contains { $0.contains(app.path) })
        XCTAssertTrue(lines.contains { $0.contains(data.path) })
        XCTAssertTrue(lines.contains { $0.contains("/fixture/shared") })
        XCTAssertTrue(lines.contains { $0.contains("/fixture/unreadable") })
        XCTAssertFalse(lines.contains { $0.hasPrefix(app.bundleSizeText + "  ") })
        XCTAssertFalse(lines.contains { $0.contains("brew uninstall") })
        XCTAssertTrue(lines.contains { $0.contains("--data-only --with-data --dry-run") })
        plan.removeApp = true
        plan.paths.insert(app.path, at: 0)
        XCTAssertTrue(AppsPage.lines(plan).contains { $0.contains("brew uninstall") })
    }

    func app(_ name: String, leftovers: [String] = []) -> InstalledApp {
        var a = InstalledApp(path: "/nonexistent-\(UUID().uuidString)/\(name).app", name: name, bundleID: "com.example.\(name)")
        a.bytes = 100
        a.leftovers = leftovers.map { AppLeftover(path: $0, bytes: 10) }
        return a
    }

    func testUninstalledAppLeavesTheListWithoutRescanning() {
        let a = app("A", leftovers: ["/x/a"]), b = app("B")
        let after = AppsModel.afterUninstall([a, b], appPath: a.path, removed: [a.path, "/x/a"])
        XCTAssertEqual(after.map(\.name), ["B"])
        XCTAssertEqual(after.first?.bytes, 100, "other apps keep their measurements")
    }

    func testAppWhoseBundleStaysKeepsOnlyUnmovedFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("A-\(UUID().uuidString).app").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var a = InstalledApp(path: dir, name: "A", bundleID: "com.example.A")
        a.leftovers = [AppLeftover(path: "/x/1", bytes: 1), AppLeftover(path: "/x/2", bytes: 2)]
        let after = AppsModel.afterUninstall([a], appPath: dir, removed: ["/x/1"])
        XCTAssertEqual(after.first?.leftovers.map(\.path), ["/x/2"])
        var reviewed = a
        reviewed.leftovers = [AppLeftover(path: "/x/1", bytes: 1), AppLeftover(path: "/new/owned", bytes: 3)]
        let fresh = AppsModel.afterUninstall([a], appPath: dir, removed: ["/x/1"], reviewed: reviewed)
        XCTAssertEqual(fresh.first?.leftovers.map(\.path), ["/new/owned"], "old ownership must not be restored after data removal")
    }

    func testRemovedLeftoversDropOut() {
        let o1 = OrphanData(bundleID: "com.gone.one", items: [AppLeftover(path: "/l/1", bytes: 1)])
        let o2 = OrphanData(bundleID: "com.gone.two", items: [AppLeftover(path: "/l/2", bytes: 1), AppLeftover(path: "/l/3", bytes: 1)])
        let after = AppsModel.afterRemoval([o1, o2], removed: ["/l/1", "/l/2"])
        XCTAssertEqual(after.map(\.bundleID), ["com.gone.two"])
        XCTAssertEqual(after.first?.items.map(\.path), ["/l/3"])
    }
}
