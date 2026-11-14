import XCTest
@testable import ThermoApp

@MainActor final class FeatureTasksTests: XCTestCase {
    func testCancellationStillWaitsForThePhysicalReaderToReturn() async {
        let tasks=FeatureTasks(),entered=expectation(description:"reader entered"),release=DispatchSemaphore(value:0)
        defer{release.signal()}
        tasks.run {entered.fulfill();_ = release.wait(timeout:.now()+5)}
        await fulfillment(of:[entered],timeout:2)
        tasks.cancel()
        var drained=false
        let finish=Task {await tasks.finish();drained=true}
        await Task.yield()
        XCTAssertFalse(drained)
        XCTAssertEqual(tasks.count,1)
        release.signal();await finish.value
        XCTAssertTrue(drained);XCTAssertEqual(tasks.count,0)
    }
    func testDrainIncludesWorkAddedByAnAlreadyRunningCompletion() async {
        let tasks=FeatureTasks(),entered=expectation(description:"second reader entered"),release=DispatchSemaphore(value:0)
        defer{release.signal()}
        tasks.run {
            _ = await MainActor.run {tasks.run {entered.fulfill();_ = release.wait(timeout:.now()+5)}}
        }
        await fulfillment(of:[entered],timeout:2)
        var drained=false
        let finish=Task {await tasks.finish();drained=true}
        await Task.yield();XCTAssertFalse(drained)
        release.signal();await finish.value
        XCTAssertTrue(drained);XCTAssertEqual(tasks.count,0)
    }
}
