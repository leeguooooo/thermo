import XCTest
@testable import NativeFeatureAPI

@MainActor final class FeatureSkippedWorkTests:XCTestCase {
    func testInitiallyDeniedWorkRunsCleanupSynchronouslyAndOnlyOnce()async {
        let work=FeatureTasks();work.enabled={false}
        var cleaned=0
        let task=work.run(onSkipped:{cleaned+=1}) {XCTFail("denied work must not execute")}
        XCTAssertEqual(cleaned,1)
        await task.value;await work.finish()
        XCTAssertEqual(cleaned,1);XCTAssertEqual(work.count,0)
    }
}
