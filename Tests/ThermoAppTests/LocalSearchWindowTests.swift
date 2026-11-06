import AppKit
import XCTest
@testable import ThermoApp

@MainActor final class LocalSearchWindowTests: XCTestCase {
    func testSearchAcceptsFirstClickFromAnotherApplication() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-search-window-" + UUID().uuidString)
        let model = LocalSearchModel(directory: directory)
        let controller = LocalSearchPanel(model: model)
        defer { controller.hide(restoreFocus: false); model.stop(); try? FileManager.default.removeItem(at: directory) }
        let content = try XCTUnwrap(controller.window?.contentView)
        XCTAssertTrue(content.acceptsFirstMouse(for: nil), "Clicking Preview from the terminal must act on the first click")
    }
    func testPreviewContentSurvivesFocusHandoffFromAnotherApplication() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-search-window-" + UUID().uuidString)
        let model = LocalSearchModel(directory: directory)
        let controller = LocalSearchPanel(model: model)
        let search = try XCTUnwrap(controller.window)
        let preview = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        preview.isReleasedWhenClosed = false; preview.delegate = controller
        let content = NSTextField(labelWithString: "The preview document must remain readable")
        preview.contentView = content
        defer {
            controller.hide(restoreFocus: false); preview.close(); model.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        search.orderFront(nil)
        controller.presentPreview(preview) {
            // App activation delivers this notification before the new document becomes visible.
            controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: search))
        }
        XCTAssertTrue(preview.contentView === content, "Activating Thermo must not close and reopen an empty preview")
        XCTAssertTrue(preview.isVisible)
        XCTAssertTrue(search.isVisible, "The search stays available behind its document")
        preview.close()
        XCTAssertTrue(search.isVisible)
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: preview))
        XCTAssertTrue(search.isVisible, "A closing document's focus notification must not dismiss the search")
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: search))
        XCTAssertFalse(search.isVisible, "Leaving search after the preview closes still dismisses it")
    }
}
