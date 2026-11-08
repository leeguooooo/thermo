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

    func sliders(in element: NSAccessibilityProtocol) -> Int {
        var count = element.accessibilityRole() == .slider ? 1 : 0
        for child in element.accessibilityChildren() ?? [] {
            if let child = child as? NSAccessibilityProtocol { count += sliders(in: child) }
        }
        return count
    }

    func testEditorFollowsEachNewPolicy() {
        let box = Box()
        let host = NSHostingView(rootView: Host(box: box))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 200)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        func settle() { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
        settle()
        XCTAssertEqual(sliders(in: host), 0, "auto: no speed slider")
        box.policy = .fixed(rpm: 3000); settle()
        XCTAssertEqual(sliders(in: host), 1, "fixed: the slider shows")
        box.policy = .auto; settle()
        XCTAssertEqual(sliders(in: host), 0, "back to auto: no slider")
        window.close()
    }

    func testSameModeIgnoresClampedNumbers() {
        XCTAssertTrue(Monitor.sameMode(.fixed(rpm: 2417), .fixed(rpm: 2500)))
        XCTAssertTrue(Monitor.sameMode(.auto, .auto))
        XCTAssertFalse(Monitor.sameMode(.auto, .fixed(rpm: 2500)))
    }
}
