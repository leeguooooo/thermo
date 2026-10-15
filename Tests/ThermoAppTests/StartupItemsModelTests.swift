@testable import CleanKit
@testable import ThermoApp
import XCTest

final class StartupItemsModelTests: XCTestCase {
    @MainActor func testRepeatedVisibleRefreshDiscardsOldScanAndRunsOneReplacement() async throws {
        let calls = Calls(), first = expectation(description: "first"), second = expectation(description: "second")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let model = StartupItemsModel(read: {
            let n = calls.next()
            if n == 1 { first.fulfill(); _ = release.wait(timeout: .now() + 5) } else { second.fulfill() }
            return StartupReport(items: [], issues: ["scan \(n)"])
        })
        var published: [String] = []
        let observation = model.$report.sink { published += $0?.issues ?? [] }
        model.refresh(); await fulfillment(of: [first], timeout: 2)
        for _ in 0..<100 { model.refresh() }
        XCTAssertEqual(calls.value, 1)
        release.signal(); await fulfillment(of: [second], timeout: 2)
        for _ in 0..<100 where model.loading { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(calls.value, 2); XCTAssertEqual(model.report?.issues, ["scan 2"])
        XCTAssertFalse(published.contains("scan 1")); observation.cancel()
    }

    @MainActor func testExplicitBackgroundInspectionIsSerializedAndDoesNotChangeStartupItems() async throws {
        let began = expectation(description: "read authorization"); began.assertForOverFulfill = true
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let model = StartupItemsModel(read: { .init(items: [], issues: []) }, change: { _, _ in XCTFail("read must not change launchctl state") }, readBackground: {
            began.fulfill(); _ = release.wait(timeout: .now() + 5)
            return .requiresAuthorization
        })
        model.inspectBackground(); await fulfillment(of: [began], timeout: 2)
        XCTAssertTrue(model.authorizing); XCTAssertTrue(model.working)
        model.apply(StartupItem(path: "/fixture", label: "fixture", enabled: true))
        model.inspectBackground(); model.retire()
        release.signal()
        for _ in 0..<100 where model.working { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.authorizing); XCTAssertFalse(model.working)
        XCTAssertEqual(model.background.status, .requiresAuthorization)
    }
    @MainActor
    func testConfirmedChangeSurvivesPageRetirementAndPreventsAnotherChange() async throws {
        let began = expectation(description: "change waiting for approval")
        let release = DispatchSemaphore(value: 0)
        let calls = Calls()
        let model = StartupItemsModel(read: { StartupReport(items: [], issues: ["readback"]) }, change: { _, _ in
            _ = calls.next(); began.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
        })
        let item = StartupItem(path: "/fixture", label: "fixture", enabled: true)
        model.apply(item)
        await fulfillment(of: [began], timeout: 5)
        model.retire()
        XCTAssertTrue(model.working)
        model.apply(item)
        model.refresh()
        XCTAssertEqual(calls.value, 1)
        release.signal()
        for _ in 0..<100 where model.working { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.working)
        XCTAssertEqual(model.report?.issues, ["readback"])
        XCTAssertNotNil(model.message)
    }

    private final class Calls: @unchecked Sendable {
        let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    @MainActor
    func testRetireAndRepeatedReopenDoNotOverlapScansOrPublishOldResult() async throws {
        let calls = Calls()
        let first = expectation(description: "first scan running")
        let second = expectation(description: "replacement scan running")
        let release = DispatchSemaphore(value: 0)
        let model = StartupItemsModel(read: {
            let n = calls.next()
            if n == 1 {
                first.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            } else { second.fulfill() }
            return StartupReport(items: [], issues: ["fixture \(n)"])
        })
        var published: [String] = []
        let observation = model.$report.sink { published += $0?.issues ?? [] }
        model.refresh()
        await fulfillment(of: [first], timeout: 5)
        model.retire()
        for _ in 0..<20 { model.refresh() }
        XCTAssertEqual(calls.value, 1, "reopen must wait for the original worker to finish")
        release.signal()
        await fulfillment(of: [second], timeout: 5)
        for _ in 0..<100 where model.loading { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.loading)
        XCTAssertEqual(calls.value, 2)
        XCTAssertEqual(model.report?.issues, ["fixture 2"])
        XCTAssertFalse(published.contains("fixture 1"))
        observation.cancel()
    }
}
