import AppKit
import SearchCore
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
    func testNewSelectionReplacesVisiblePreviewAndSameSelectionTogglesItClosed() async throws {
        _=NSApplication.shared
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-preview-switch-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let firstURL=directory.appendingPathComponent("A-"+UUID().uuidString+".pdf"),secondURL=directory.appendingPathComponent("B-"+UUID().uuidString+".pdf")
        for url in [firstURL,secondURL] {try Data("%PDF-1.4 fixture".utf8).write(to:url)}
        let first=SearchItem(path:firstURL.path,name:firstURL.lastPathComponent,kind:.file)
        let second=SearchItem(path:secondURL.path,name:secondURL.lastPathComponent,kind:.file)
        let model=LocalSearchModel(directory:directory.appendingPathComponent("index")) {term,_ in .init(query:term,items:[term=="first" ? first:second])}
        let controller=LocalSearchPanel(model:model)
        controller.window?.alphaValue=0
        defer {controller.hide(restoreFocus:false);model.stop();try? FileManager.default.removeItem(at:directory)}
        model.query="first"
        for _ in 0..<100 where model.selected?.path != first.path {try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertEqual(model.selected?.path,first.path)
        controller.previewSelected()
        let firstWindow=try XCTUnwrap(NSApp.windows.first{$0.title==first.name && $0.isVisible})
        firstWindow.alphaValue=0
        model.query="second"
        for _ in 0..<100 where model.selected?.path != second.path {try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertEqual(model.selected?.path,second.path)
        controller.previewSelected()
        let secondWindow=NSApp.windows.first{$0.title==second.name && $0.isVisible}
        XCTAssertNotNil(secondWindow,"changing the selected file must open its preview on the first request")
        XCTAssertFalse(firstWindow.isVisible)
        secondWindow?.alphaValue=0
        controller.previewSelected()
        XCTAssertFalse(secondWindow?.isVisible ?? false,"requesting the same file again still toggles its preview closed")
        controller.hide(restoreFocus:false);model.stop()
        await model.finishStopping()
        SearchPreviewController.shared.stop();await SearchPreviewController.shared.finishStopping()
    }

}
