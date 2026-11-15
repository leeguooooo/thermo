import ThermoUI
import AppKit
import Combine
import SwiftUI
import XCTest
@testable import ThermoShell
@testable import ThermoComposition

final class VisibleSamplingTests: ThermoCompositionTestCase {
    private final class State: ObservableObject {
        @Published var visible = true
    }
    private struct Probe: View {
        @ObservedObject var state: State
        let changed: (UUID, Bool) -> Void
        var body: some View {
            Text("visibility fixture")
                .samplingWhileVisible(changed)
                .environment(\.windowSamplingActive, state.visible)
        }
    }

    @MainActor func testOcclusionPausesAndResumingKeepsTheSameLease() async {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 200, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let state = State()
        let began = expectation(description: "visible page starts")
        let paused = expectation(description: "occluded page stops")
        let resumed = expectation(description: "revealed page restarts")
        let retired = expectation(description: "retired page stops")
        var events: [(UUID, Bool)] = []
        window.contentViewController = NSHostingController(rootView: Probe(state: state) { owner, active in
            events.append((owner, active))
            switch events.count {
            case 1: began.fulfill()
            case 2: paused.fulfill()
            case 3: resumed.fulfill()
            case 4: retired.fulfill()
            default: XCTFail("duplicate sampling transition")
            }
        })
        window.orderBack(nil)
        await fulfillment(of: [began], timeout: 5)
        state.visible = false
        await fulfillment(of: [paused], timeout: 5)
        state.visible = true
        await fulfillment(of: [resumed], timeout: 5)
        MainWindow.retireContent(in: window)
        await fulfillment(of: [retired], timeout: 5)
        XCTAssertEqual(events.map(\.1), [true, false, true, false])
        XCTAssertEqual(Set(events.map(\.0)).count, 1)
        window.orderOut(nil)
    }

}
