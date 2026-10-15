@testable import CleanKit
@testable import ThermoApp
import XCTest

final class StartupItemsModelTests: XCTestCase {
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
