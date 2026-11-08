import AppKit
import SwiftUI
import XCTest
import ThermoKit
@testable import ThermoApp

/// The fan card's editor must follow the policy it is given. It once reloaded the previous policy after Apply,
/// so the picker flipped back to the old mode and a second Apply undid the change.
@MainActor final class FanControlCardTests: XCTestCase {
    final class Box: ObservableObject { @Published var policy: FanPolicy = .auto }
    struct Host: View {
        @ObservedObject var box: Box
        let fan = FanReading(id: 0, name: "Fan", rpm: 2500, min: 2300, max: 6500, target: nil, manual: false)
        var body: some View { FanControlCard(fan: fan, policy: box.policy, enabled: true) { _ in }.frame(width: 700) }
    }

    /// Height of the card as SwiftUI lays it out: fixed mode adds the speed slider row, auto shows no editor.
    func height(_ policy: FanPolicy) -> CGFloat {
        let box = Box(); box.policy = policy
        let host = NSHostingView(rootView: Host(box: box))
        host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return host.fittingSize.height
    }

    func testEditorFollowsEachNewPolicy() {
        let autoHeight = height(.auto), fixedHeight = height(.fixed(rpm: 3000))
        XCTAssertGreaterThan(fixedHeight, autoHeight, "fixed mode shows the slider")

        let box = Box()
        let host = NSHostingView(rootView: Host(box: box))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        func settle() -> CGFloat { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.4)); return host.fittingSize.height }
        XCTAssertEqual(settle(), autoHeight, accuracy: 0.5)
        box.policy = .fixed(rpm: 3000)
        XCTAssertEqual(settle(), fixedHeight, accuracy: 0.5, "after Apply to fixed the editor shows fixed, not the previous auto")
        box.policy = .auto
        XCTAssertEqual(settle(), autoHeight, accuracy: 0.5, "after Apply to auto the editor shows auto, not the previous fixed")
        window.close()
    }

    func testSameModeIgnoresClampedNumbers() {
        XCTAssertTrue(Monitor.sameMode(.fixed(rpm: 2417), .fixed(rpm: 2500)))
        XCTAssertTrue(Monitor.sameMode(.auto, .auto))
        XCTAssertFalse(Monitor.sameMode(.auto, .fixed(rpm: 2500)))
    }

    func testApplyHasNothingToSendWhenTheEditorMatchesThePolicy() {
        let range = (min: 2317.0, max: 6550.0)
        XCTAssertTrue(FanControlCard.matches(mode: .auto, rpm: 0, curve: nil, policy: .auto, range: range))
        XCTAssertTrue(FanControlCard.matches(mode: .fixed, rpm: 2498, curve: nil, policy: .fixed(rpm: 2498), range: range))
        XCTAssertTrue(FanControlCard.matches(mode: .fixed, rpm: 6550, curve: nil, policy: .fixed(rpm: .infinity), range: range))
        XCTAssertFalse(FanControlCard.matches(mode: .fixed, rpm: 3000, curve: nil, policy: .fixed(rpm: 2498), range: range))
        XCTAssertFalse(FanControlCard.matches(mode: .fixed, rpm: 2498, curve: nil, policy: .auto, range: range))
        XCTAssertFalse(FanControlCard.matches(mode: .fixed, rpm: 2498, curve: nil, policy: .fixed(rpm: 2498), range: nil))
        let curve = try! FanCurve(parsing: "50:min,70:3000,85:max")
        var gpu = curve; gpu.sensor = .gpu
        XCTAssertTrue(FanControlCard.matches(mode: .curve, rpm: 0, curve: curve, policy: .curve(curve), range: range))
        XCTAssertFalse(FanControlCard.matches(mode: .curve, rpm: 0, curve: gpu, policy: .curve(curve), range: range))
        XCTAssertFalse(FanControlCard.matches(mode: .curve, rpm: 0, curve: nil, policy: .curve(curve), range: range), "an unparsable custom curve is not a match")
    }

    func testReturningToAutoIsRecordedAsDone() {
        // The helper reports automatic fans by leaving them out of its policy table.
        XCTAssertTrue(Monitor.fanChangeApplied(fan: 0, policy: .auto, active: [:], error: nil))
        XCTAssertTrue(Monitor.fanChangeApplied(fan: 0, policy: .fixed(rpm: 2500), active: [0: .fixed(rpm: 2498)], error: nil))
        XCTAssertFalse(Monitor.fanChangeApplied(fan: 0, policy: .fixed(rpm: 2500), active: [:], error: nil))
        XCTAssertFalse(Monitor.fanChangeApplied(fan: 0, policy: .auto, active: [0: .fixed(rpm: 2498)], error: nil))
        XCTAssertFalse(Monitor.fanChangeApplied(fan: 0, policy: .auto, active: nil, error: nil), "no readback is not success")
        XCTAssertFalse(Monitor.fanChangeApplied(fan: 0, policy: .auto, active: [:], error: "helper down"))
    }
}
