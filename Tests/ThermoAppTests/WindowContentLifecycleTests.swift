import AppKit
import SwiftUI
@testable import ThermoApp
import XCTest

final class WindowContentLifecycleTests: XCTestCase {
    @MainActor
    func testSwiftUIAppearanceTasksStopAndCanRestart() async {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 900, height: 640),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let appeared = expectation(description: "first page appears")
        let retired = expectation(description: "retired page disappears")
        let reopened = expectation(description: "replacement page appears")
        MainWindow.restoreContent(in: window) {
            NSHostingController(rootView: Text("lifecycle fixture")
                .onAppear { appeared.fulfill() }
                .onDisappear { retired.fulfill() })
        }
        window.orderBack(nil)
        await fulfillment(of: [appeared], timeout: 5)
        MainWindow.retireContent(in: window)
        await fulfillment(of: [retired], timeout: 5)
        MainWindow.restoreContent(in: window) {
            NSHostingController(rootView: Text("restored fixture").onAppear { reopened.fulfill() })
        }
        await fulfillment(of: [reopened], timeout: 5)
        MainWindow.retireContent(in: window)
        window.orderOut(nil)
    }

    @MainActor
    func testRetiringReleasesControllerAndRestoringKeepsPlacement() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 120, y: 180, width: 900, height: 640),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let originalFrame = window.frame
        weak var retired: NSViewController?
        autoreleasepool {
            let controller = NSViewController()
            controller.view = NSView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
            retired = controller
            MainWindow.restoreContent(in: window) { controller }
            XCTAssertTrue(window.contentViewController === controller)
            MainWindow.restoreContent(in: window) { XCTFail("visible content must not be rebuilt"); return NSViewController() }
            MainWindow.retireContent(in: window)
            XCTAssertNil(window.contentViewController)
            XCTAssertNil(controller.view.window)
            XCTAssertEqual(window.frame, originalFrame)
        }
        XCTAssertNil(retired, "the old page controller must not be retained by the window")
        let replacement = NSViewController()
        replacement.view = NSView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
        MainWindow.restoreContent(in: window) { replacement }
        XCTAssertTrue(window.contentViewController === replacement)
        XCTAssertEqual(window.frame, originalFrame)
        MainWindow.retireContent(in: window)
    }
}
