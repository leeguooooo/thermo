import AppKit
import Combine
import SwiftUI
import XCTest
@testable import ThermoApp

final class VisibleSamplingTests: XCTestCase {
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

    private final class SlowPanel: @unchecked Sendable {
        let began = XCTestExpectation(description: "physical read began off main thread")
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var calls = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
        func read() -> PanelModel.Reading {
            XCTAssertFalse(Thread.isMainThread)
            lock.lock(); calls += 1; let call = calls; lock.unlock()
            if call == 1 { began.fulfill(); _ = release.wait(timeout: .now() + 15) }
            return .init(cpu: Double(call))
        }
    }

    @MainActor func testPanelSlowReadDoesNotBlockMainThreadOrPublishAfterHiding() async {
        let reader = SlowPanel()
        defer { reader.release.signal() }
        let panel = PanelModel(readBackground: { reader.read() }, holdPulse: {}, releasePulse: {})
        defer { panel.setActive(false) }
        let fresh = expectation(description: "reopened panel gets a fresh read after old read drains")
        var values: [Double] = []
        let observation = panel.$currentCPU.compactMap { $0 }.sink { value in
            values.append(value)
            if value == 2 { fresh.fulfill() }
        }
        panel.setActive(true)
        await fulfillment(of: [reader.began], timeout: 5)
        panel.setActive(false)
        panel.setActive(true)
        XCTAssertEqual(reader.count, 1)
        XCTAssertNil(panel.currentCPU)
        reader.release.signal()
        await fulfillment(of: [fresh], timeout: 5)
        XCTAssertEqual(values, [2])
        XCTAssertFalse(panel.sampleInFlight)
        withExtendedLifetime(observation) {}
    }
}
