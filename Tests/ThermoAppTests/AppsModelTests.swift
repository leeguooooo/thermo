@testable import CleanKit
@testable import ThermoApp
import XCTest
import AppKit

final class AppsModelTests: XCTestCase {
    private final class OrphanCalls: @unchecked Sendable {
        let lock = NSLock()
        private var calls = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; calls += 1; return calls }
        var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    }

    private final class ConfirmedOrphans: @unchecked Sendable {
        let lock = NSLock()
        private var items: [OrphanData] = []
        func set(_ value: [OrphanData]) { lock.lock(); items = value; lock.unlock() }
        var paths: [String] { lock.lock(); defer { lock.unlock() }; return items.flatMap { $0.items.map(\.path) } }
    }

    @MainActor func testPreparedOrphanConfirmationKeepsValuesAfterRawListRefresh() async throws {
        let reads = OrphanCalls(), captured = ConfirmedOrphans()
        let first = OrphanData(bundleID: "com.example.same", items: [.init(path: "/fixture/original", bytes: 1)])
        let replacement = OrphanData(bundleID: first.bundleID, items: [.init(path: "/fixture/replacement", bytes: 2)])
        let ready = expectation(description: "prepared confirmation"), refreshed = expectation(description: "new raw list"), removed = expectation(description: "confirmed values")
        let model = AppsModel(readOrphans: { _ in
            if reads.next() == 1 { return [first] }
            refreshed.fulfill(); return [replacement]
        }, prepareOrphanData: { data, _ in data }, removeOrphanData: { data in
            captured.set(data); removed.fulfill(); return []
        })
        let observation = model.$orphanReview.sink { if $0 != nil { ready.fulfill() } }
        defer { observation.cancel() }
        model.scanOrphans()
        for _ in 0..<100 where model.scanningOrphans { try await Task.sleep(nanoseconds: 10_000_000) }
        model.selectedOrphans = [first.id]
        model.reviewPickedOrphans()
        await fulfillment(of: [ready], timeout: 2)
        let confirmation = try XCTUnwrap(model.orphanReview)
        model.scanOrphans(); await fulfillment(of: [refreshed], timeout: 2)
        for _ in 0..<100 where model.scanningOrphans { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.pickedOrphans.first?.items.first?.path, "/fixture/replacement")
        XCTAssertEqual(model.orphanReview?.items.first?.items.first?.path, "/fixture/original")
        model.removeOrphans(confirmation.items)
        await fulfillment(of: [removed], timeout: 2)
        XCTAssertEqual(captured.paths, ["/fixture/original"])
    }

    @MainActor func testRetiredOrphanPreparationStaysSingleFlightAndCannotPublishOldSheet() async throws {
        let prepares = OrphanCalls(), reads = OrphanCalls()
        let began = expectation(description: "physical preparation"), refreshed = expectation(description: "queued scan")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let data = OrphanData(bundleID: "com.example.fixture", items: [.init(path: "/fixture", bytes: 1)])
        let model = AppsModel(readOrphans: { _ in
            if reads.next() == 2 { refreshed.fulfill() }
            return [data]
        }, prepareOrphanData: { picked, _ in
            _ = prepares.next(); began.fulfill(); _ = release.wait(timeout: .now() + 5); return picked
        })
        model.scanOrphans()
        for _ in 0..<100 where model.scanningOrphans { try await Task.sleep(nanoseconds: 10_000_000) }
        model.selectedOrphans = [data.id]; model.reviewPickedOrphans()
        await fulfillment(of: [began], timeout: 2)
        model.retire()
        for _ in 0..<100 { model.reviewPickedOrphans(); model.scanOrphans() }
        XCTAssertTrue(model.reviewingOrphans)
        XCTAssertEqual(prepares.count, 1); XCTAssertEqual(reads.count, 1)
        release.signal(); await fulfillment(of: [refreshed], timeout: 2)
        for _ in 0..<100 where model.scanningOrphans { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.reviewingOrphans); XCTAssertNil(model.orphanReview)
        XCTAssertEqual(prepares.count, 1); XCTAssertEqual(reads.count, 2)
    }

    @MainActor func testPartialOrphanScanRetainsKnownRowsButRequiresNewReviewUntilACompleteResult() async throws {
        let calls = OrphanCalls()
        let data = OrphanData(bundleID: "com.example.known", items: [AppLeftover(path: "/fixture", bytes: 1)])
        let model = AppsModel(readOrphanReport: { _ in
            switch calls.next() {
            case 1: return .init(items: [data])
            case 2: return .init(issues: [.init("Could not read residual data directory", path: "/fixture")])
            default: return .init()
            }
        })
        model.scanOrphans()
        for _ in 0..<100 where model.scanningOrphans { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(model.orphanScanComplete)
        model.selectedOrphans = [data.id]
        model.scanOrphans()
        for _ in 0..<100 where model.scanningOrphans { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.orphanScanComplete); XCTAssertEqual(model.orphanIssues.count, 1)
        XCTAssertEqual(model.orphans?.map(\.id), [data.id]); XCTAssertTrue(model.pickedOrphans.isEmpty)
        XCTAssertNotNil(model.orphans?.first?.blocked)
        model.scanOrphans()
        for _ in 0..<100 where model.scanningOrphans { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(model.orphanScanComplete); XCTAssertTrue(model.orphanIssues.isEmpty); XCTAssertEqual(model.orphans, [])
    }

    @MainActor func testOrphanRefreshAfterRestoreWaitsForOldWorkerAndDoesNotPublishItsResults() async throws {
        let calls = OrphanCalls(), first = expectation(description: "old scan"), second = expectation(description: "replacement")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let model = AppsModel(readOrphans: { _ in
            let n = calls.next()
            if n == 1 { first.fulfill(); _ = release.wait(timeout: .now() + 5) } else { second.fulfill() }
            return [OrphanData(bundleID: "com.example.scan\(n)", items: [])]
        })
        var published: [String] = []
        let observation = model.$orphans.sink { published += $0?.map(\.bundleID) ?? [] }
        model.scanOrphans(); await fulfillment(of: [first], timeout: 2)
        model.invalidateAfterRestore()
        for _ in 0..<100 { model.scanOrphans() }
        XCTAssertEqual(calls.count, 1); XCTAssertTrue(model.scanningOrphans)
        release.signal(); await fulfillment(of: [second], timeout: 2)
        for _ in 0..<100 where model.scanningOrphans { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(model.orphans?.map(\.bundleID), ["com.example.scan2"])
        XCTAssertFalse(published.contains("com.example.scan1")); observation.cancel()
    }

    @MainActor func testOrphanRemovalSurvivesRetirementAndSerializesFurtherReadsAndWrites() async throws {
        let reads = OrphanCalls(), writes = OrphanCalls()
        let began = expectation(description: "orphan removal")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let data = OrphanData(bundleID: "com.example.orphan", items: [AppLeftover(path: "/fixture", bytes: 1)])
        let model = AppsModel(readOrphans: { _ in _ = reads.next(); return [data] }, removeOrphanData: { _ in
            _ = writes.next(); began.fulfill(); _ = release.wait(timeout: .now() + 5)
            return [CleanResult(id: "leftovers:fixture", trashed: true)]
        })
        model.scanOrphans()
        for _ in 0..<100 where model.scanningOrphans { try await Task.sleep(nanoseconds: 10_000_000) }
        model.selectedOrphans = [data.id]
        model.removeOrphans([data]); await fulfillment(of: [began], timeout: 2)
        model.retire(); model.removeOrphans([data]); model.scanOrphans(); model.load()
        XCTAssertTrue(model.working); XCTAssertEqual(reads.count, 1); XCTAssertEqual(writes.count, 1)
        let previous = AppModels.shared.apps; AppModels.shared.apps = model
        defer { AppModels.shared.apps = previous }
        XCTAssertEqual(AppExitGuard.reply(show: { _ in }), .terminateCancel)
        release.signal()
        for _ in 0..<100 where model.working { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.working)
    }

    @MainActor func testRetiredOrphanReadCannotRepopulateThePage() async throws {
        let began = expectation(description: "scan")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let model = AppsModel(readOrphans: { _ in
            began.fulfill(); _ = release.wait(timeout: .now() + 5)
            return [OrphanData(bundleID: "com.example.old", items: [])]
        })
        model.scanOrphans(); await fulfillment(of: [began], timeout: 2)
        model.retire(); release.signal()
        for _ in 0..<100 where model.scanningOrphans { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.scanningOrphans); XCTAssertNil(model.orphans)
    }

    @MainActor func testQueuedOrphanRefreshDoesNotLeaveBusyStateWhenAnUninstallBegins() async throws {
        let readBegan = expectation(description: "read"), removalBegan = expectation(description: "removal")
        let readRelease = DispatchSemaphore(value: 0), removalRelease = DispatchSemaphore(value: 0)
        defer { readRelease.signal(); removalRelease.signal() }
        let model = AppsModel(remove: { _ in
            removalBegan.fulfill(); _ = removalRelease.wait(timeout: .now() + 5)
            return CleanResult(id: "fixture", trashed: true)
        }, readOrphans: { _ in
            readBegan.fulfill(); _ = readRelease.wait(timeout: .now() + 5)
            return []
        })
        model.scanOrphans(); await fulfillment(of: [readBegan], timeout: 2)
        model.scanOrphans()
        model.uninstall(UninstallPlan(app: InstalledApp(path: "/fixture.app", name: "Fixture", bundleID: nil), paths: [], bytes: 0))
        await fulfillment(of: [removalBegan], timeout: 2)
        readRelease.signal()
        for _ in 0..<100 where model.scanningOrphans { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.scanningOrphans)
        removalRelease.signal()
        for _ in 0..<100 where model.working { try await Task.sleep(nanoseconds: 10_000_000) }
    }

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
        let retained = AppsPage.retainedLines(plan)
        let details = AppsPage.detailLines(plan)
        XCTAssertFalse(lines.contains { $0.contains(app.path) })
        XCTAssertTrue(retained.contains { $0.contains(app.path) })
        XCTAssertTrue(lines.contains { $0.contains(data.path) })
        XCTAssertTrue(retained.contains { $0.contains("/fixture/shared") })
        XCTAssertFalse(lines.contains { $0.contains("/fixture/shared") })
        XCTAssertTrue(details.contains { $0.contains("/fixture/unreadable") })
        XCTAssertFalse(lines.contains { $0.hasPrefix(app.bundleSizeText + "  ") })
        XCTAssertFalse(lines.contains { $0.contains("brew uninstall") })
        XCTAssertTrue(details.contains { $0.contains("--data-only --with-data --dry-run") })
        plan.removeApp = true
        plan.paths.insert(app.path, at: 0)
        XCTAssertTrue(AppsPage.detailLines(plan).contains { $0.contains("brew uninstall") })
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
