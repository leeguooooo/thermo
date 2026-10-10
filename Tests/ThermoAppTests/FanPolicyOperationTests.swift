import XCTest
import ThermoKit
@testable import ThermoApp

final class FanPolicyOperationTests: XCTestCase {
    enum Failure: Error { case write, read }

    func testMultiplePendingFansApplyInOrderBeforeReadback() async {
        var events: [String] = []
        let result = await FanPolicyOperation.run([(0, .fixed(rpm: 3000)), (1, .auto)], set: { _, fan in
            events.append("set \(fan)")
            await Task.yield()
        }, read: {
            events.append("read")
            return [0: .fixed(rpm: 3000), 1: .auto]
        })
        XCTAssertEqual(events, ["set 0", "set 1", "read"])
        XCTAssertEqual(result.policies, [0: .fixed(rpm: 3000), 1: .auto])
        XCTAssertNil(result.error)
    }

    func testFailedWriteStillReadsActualPoliciesAndTriesOtherFans() async {
        var attempted: [Int] = []
        let result = await FanPolicyOperation.run([(0, .fixed(rpm: 3000)), (1, .auto)], set: { _, fan in
            attempted.append(fan)
            if fan == 0 { throw Failure.write }
        }, read: { [0: .auto, 1: .auto] })
        XCTAssertEqual(attempted, [0, 1])
        XCTAssertEqual(result.policies, [0: .auto, 1: .auto])
        XCTAssertNotNil(result.error)
    }

    func testFailedReadbackDoesNotPretendRequestedPolicyIsActive() async {
        let result = await FanPolicyOperation.run([(0, .fixed(rpm: 3000))], set: { _, _ in }, read: { throw Failure.read })
        XCTAssertNil(result.policies)
        XCTAssertNotNil(result.error)
    }
}
