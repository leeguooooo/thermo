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
    func testStoppingWaitsForAnAcceptedProtectedOperationAndRefusesAnother() async throws {
        let tasks=FeatureTasks(),operation=try XCTUnwrap(tasks.beginOperation())
        tasks.stop()
        XCTAssertNil(tasks.beginOperation())
        var drained=false
        let finish=Task{await tasks.finish();drained=true}
        await Task.yield();XCTAssertFalse(drained)
        tasks.endOperation(operation);await finish.value
        XCTAssertTrue(drained);XCTAssertFalse(tasks.hasOperations)
    }

    func testStopRejectsQueuedMainActorAndDetachedWorkBeforeItsBodyStarts() async {
        let tasks=FeatureTasks()
        var mainCalls=0
        let detached=expectation(description:"detached body must not enter")
        detached.isInverted=true
        tasks.runOnMain {mainCalls += 1}
        tasks.run {detached.fulfill()}
        tasks.stop()
        await tasks.finish()
        XCTAssertEqual(mainCalls,0);XCTAssertEqual(tasks.count,0)
        await fulfillment(of:[detached],timeout:0.05)
    }

}
