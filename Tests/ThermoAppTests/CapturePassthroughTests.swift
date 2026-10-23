import AppKit
import CaptureCore
import CaptureScriptCore
import XCTest
@testable import ThermoApp

@MainActor final class CapturePassthroughTests:XCTestCase {
    private func image() throws -> CGImage {
        _=NSApplication.shared
        let ctx=try XCTUnwrap(CGContext(data:nil,width:80,height:60,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(NSColor.blue.cgColor);ctx.fill(CGRect(x:0,y:0,width:80,height:60));return try XCTUnwrap(ctx.makeImage())
    }
    func testTemporaryModeUpdatesNativeWindowWithoutChangingPixelsOrSavedTitle() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),session=CapturePinSession(store:.init(root:root))
        defer{session.closeAll();try? FileManager.default.removeItem(at:root)}
        let id=try session.open(image()),editor=try XCTUnwrap(session.windows[id]),model=editor.model
        model.pinTitle="Fixture";try session.flush();let revision=session.library.revision,pixels=try model.document.data(),imageRevision=model.revision
        model.mousePassthrough=true
        XCTAssertTrue(editor.window?.ignoresMouseEvents == true);XCTAssertTrue(editor.window?.title.hasPrefix("Fixture · ") == true)
        XCTAssertEqual(model.revision,imageRevision);XCTAssertEqual(session.library.revision,revision);XCTAssertEqual(try model.document.data(),pixels)
        model.mousePassthrough=false;XCTAssertFalse(editor.window?.ignoresMouseEvents ?? true);XCTAssertEqual(editor.window?.title,"Fixture")
        model.mousePassthrough=true;try session.flush()
        XCTAssertEqual(session.library.pins.first?.title,"Fixture")
        let manifest=try String(contentsOf:root.appendingPathComponent("library.json"));XCTAssertFalse(manifest.contains("mousePassthrough"))
    }
    func testRecoveryIncludesHiddenGroupsAndWorksWhileSavingIsBlocked() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),session=CapturePinSession(store:.init(root:root))
        defer{for editor in session.windows.values {editor.model.pinContentSaveError=nil};session.closeAll();try? FileManager.default.removeItem(at:root)}
        let first=try session.open(image());session.windows[first]?.model.mousePassthrough=true
        _=try session.createGroup(name:"Other")
        let second=try session.open(image());session.windows[second]?.model.mousePassthrough=true;session.windows[second]?.model.locked=true
        session.windows[first]?.model.pinContentSaveError="fixture blocks save"
        XCTAssertThrowsError(try session.flush())
        session.restoreMouseInteraction()
        for editor in session.windows.values {XCTAssertFalse(editor.model.mousePassthrough);XCTAssertFalse(editor.window?.ignoresMouseEvents ?? true)}
        XCTAssertTrue(session.windows[second]?.model.locked == true)
    }
    func testShowingAndReopeningPinsAlwaysProvideInteractiveRecovery() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),session=CapturePinSession(store:.init(root:root))
        defer{session.closeAll();try? FileManager.default.removeItem(at:root)}
        let id=try session.open(image()),model=try XCTUnwrap(session.windows[id]?.model)
        model.locked=true;model.mousePassthrough=true
        try session.showPin(id);XCTAssertFalse(model.mousePassthrough)
        model.mousePassthrough=true;session.closeAll()
        let reopened=CapturePinSession(store:.init(root:root));defer{reopened.closeAll()}
        try reopened.restore(id);let editor=try XCTUnwrap(reopened.windows[id])
        XCTAssertTrue(editor.model.locked);XCTAssertFalse(editor.model.mousePassthrough);XCTAssertFalse(editor.window?.ignoresMouseEvents ?? true)
    }
    func testGlobalAndScriptActionsAndPointerLookupUseOwnPinWindows() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),session=CapturePinSession(store:.init(root:root)),workspace=CaptureWorkspace(pinSession:session)
        defer{workspace.shutdown();session.closeAll();try? FileManager.default.removeItem(at:root)}
        XCTAssertNoThrow(try workspace.perform(.restoreMouseInteraction))
        XCTAssertThrowsError(try workspace.perform(.togglePassthrough))
        let id=try session.open(image()),editor=try XCTUnwrap(session.windows[id]),window=try XCTUnwrap(editor.window)
        editor.model.locked=true
        try workspace.perform(.togglePassthrough);XCTAssertTrue(editor.model.mousePassthrough)
        XCTAssertTrue(session.editorUnderMouse(at:CGPoint(x:window.frame.midX,y:window.frame.midY)) === editor)
        XCTAssertNil(session.editorUnderMouse(at:CGPoint(x:-100000,y:-100000)))
        let result=try await workspace.performScriptAction("restoreMouseInteraction")
        XCTAssertEqual(result,.bool(true));XCTAssertFalse(editor.model.mousePassthrough);XCTAssertFalse(window.ignoresMouseEvents)
        XCTAssertTrue(editor.model.locked)
    }
}
