import XCTest
import ThermoKit
import ThermoKernel

final class FanPolicyJournalTests: XCTestCase {
    func testSameModeIgnoresClampedNumbers() {
        XCTAssertTrue(FanPolicyJournal.sameMode(.fixed(rpm: 2417), .fixed(rpm: 2500)))
        XCTAssertTrue(FanPolicyJournal.sameMode(.auto, .auto))
        XCTAssertFalse(FanPolicyJournal.sameMode(.auto, .fixed(rpm: 2500)))
    }

    func testReturningToAutoIsRecordedAsDone() {
        // The helper reports automatic fans by leaving them out of its policy table.
        XCTAssertTrue(FanPolicyJournal.fanChangeApplied(fan: 0, policy: .auto, active: [:], error: nil))
        XCTAssertTrue(FanPolicyJournal.fanChangeApplied(fan: 0, policy: .fixed(rpm: 2500), active: [0: .fixed(rpm: 2498)], error: nil))
        XCTAssertFalse(FanPolicyJournal.fanChangeApplied(fan: 0, policy: .fixed(rpm: 2500), active: [:], error: nil))
        XCTAssertFalse(FanPolicyJournal.fanChangeApplied(fan: 0, policy: .auto, active: [0: .fixed(rpm: 2498)], error: nil))
        XCTAssertFalse(FanPolicyJournal.fanChangeApplied(fan: 0, policy: .auto, active: nil, error: nil), "no readback is not success")
        XCTAssertFalse(FanPolicyJournal.fanChangeApplied(fan: 0, policy: .auto, active: [:], error: "helper down"))
    }
}
