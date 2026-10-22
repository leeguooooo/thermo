import AppKit
import XCTest
import ThermoKit
@testable import ThermoApp

@MainActor final class PanelPopoverTests: XCTestCase {
    func testPanelIsSizedForItsScreenAndStaysPutWhileOpen() async throws {
        let monitor = Monitor(startMonitoring: false, helperInteraction: false)
        let popover = NSPopover()
        popover.animates = false
        popover.contentViewController = PanelPopover.host(monitor)
        PanelPopover.size(popover, visibleHeight: 700)
        XCTAssertEqual(popover.contentSize.width, 372)
        XCTAssertEqual(popover.contentSize.height, 676)
        PanelPopover.size(popover, visibleHeight: 2000)
        XCTAssertGreaterThan(popover.contentSize.height, 676)
        XCTAssertLessThan(popover.contentSize.height, 1976)
        PanelPopover.size(popover, visibleHeight: 700)
        let anchor = NSWindow(contentRect: NSRect(x: 200, y: 800, width: 20, height: 20), styleMask: .borderless, backing: .buffered, defer: false)
        anchor.orderFrontRegardless()
        defer { popover.close(); anchor.orderOut(nil) }
        popover.show(relativeTo: anchor.contentView!.bounds, of: anchor.contentView!, preferredEdge: .minY)
        let window = try XCTUnwrap(popover.contentViewController?.view.window)
        let initial = window.frame.size
        for step in 0..<4 {
            monitor.lastError = step.isMultiple(of: 2) ? String(repeating: "Readback unavailable. ", count: 30) : nil
            monitor.iconHidden = step.isMultiple(of: 2)
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertEqual(window.frame.size, initial, "step \(step)")
        }
    }
}
