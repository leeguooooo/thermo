import AppKit
import CaptureCore
import CaptureScriptCore
import XCTest
@testable import ThermoApp

@MainActor final class CapturePinLockTests:XCTestCase {
    private func image() throws -> CGImage {
        _=NSApplication.shared
        let ctx=try XCTUnwrap(CGContext(data:nil,width:80,height:60,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(NSColor.white.cgColor);ctx.fill(CGRect(x:0,y:0,width:80,height:60))
        ctx.setFillColor(NSColor.red.cgColor);ctx.fill(CGRect(x:0,y:0,width:25,height:60))
        return try XCTUnwrap(ctx.makeImage())
    }
    private func worker() throws -> URL {
        var folder=Bundle(for:Self.self).bundleURL
        for _ in 0..<8 {let file=folder.appendingPathComponent("thermo-capture-script");if FileManager.default.isExecutableFile(atPath:file.path){return file};folder.deleteLastPathComponent()}
        throw CaptureScriptFailure.unavailable
    }
    private func pinLocked(_ error:Error,file:StaticString=#filePath,line:UInt=#line) {
        if case CaptureActionFailure.pinLocked=error {} else {XCTFail("Expected pin lock rejection, got \(error)",file:file,line:line)}
    }
    func testLockedModelKeepsPixelsHistoryAndStylesUntilUnlocked() throws {
        let model=CaptureEditorModel(image:try image())
        model.document.append(.init(tool:.rectangle,points:[CGPoint(x:5,y:5),CGPoint(x:30,y:30)]))
        model.document.append(.init(tool:.ellipse,points:[CGPoint(x:40,y:10),CGPoint(x:60,y:30)]));model.undoAnnotation();model.selectAnnotation(0)
        let before=try model.document.data(),revision=model.revision
        XCTAssertTrue(model.document.canUndo);XCTAssertTrue(model.document.canRedo)
        model.locked=true;model.color = .green;model.lineWidth=10;model.text="changed";model.applySelectedStyle()
        model.undoAnnotation();model.redoAnnotation();model.deleteSelected()
        XCTAssertThrowsError(try model.transformImage(rotateClockwise:true)){self.pinLocked($0)}
        XCTAssertThrowsError(try model.transformImage(flipHorizontal:true)){self.pinLocked($0)}
        XCTAssertEqual(try model.document.data(),before);XCTAssertEqual(model.revision,revision)
        XCTAssertTrue(model.document.canUndo);XCTAssertTrue(model.document.canRedo)
        model.locked=false;model.redoAnnotation();XCTAssertEqual(model.document.annotations.count,2)
        try model.transformImage(rotateClockwise:true);XCTAssertEqual(model.document.image.width,60);XCTAssertEqual(model.document.image.height,80)
    }
    func testMenuAndScriptEditsRejectLockedPinWithoutChangingViewOrPixels() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),session=CapturePinSession(store:.init(root:root)),workspace=CaptureWorkspace(pinSession:session)
        defer{workspace.shutdown();session.closeAll();try? FileManager.default.removeItem(at:root)}
        let id=try session.open(image()),model=try XCTUnwrap(session.windows[id]?.model)
        model.document.append(.init(tool:.rectangle,points:[.zero,CGPoint(x:25,y:25)]));model.zoom=1.7;model.pan=CGPoint(x:12,y:7);model.locked=true
        let before=try model.document.data(),revision=model.revision
        for action in [CaptureAction.rotate,.flip,.undo,.redo,.resetZoom] {
            XCTAssertThrowsError(try workspace.perform(action)){self.pinLocked($0)}
            do {_=try await workspace.performScriptAction(action.rawValue);XCTFail("Locked script action")} catch {pinLocked(error)}
        }
        workspace.scriptWorker=try worker()
        let result=try await workspace.executeScript("try{thermo.perform('rotate');return 'unexpected'}catch(e){return e.message}")
        guard case .string(let message)=result.value else {return XCTFail("Missing script rejection")};XCTAssertTrue(message.contains("Unlock"))
        XCTAssertEqual(model.revision,revision);XCTAssertEqual(try model.document.data(),before);XCTAssertEqual(model.zoom,1.7);XCTAssertEqual(model.pan,CGPoint(x:12,y:7))
        try workspace.perform(.toggleLock);try workspace.perform(.rotate);XCTAssertEqual(model.document.image.width,60)
    }
    func testLockedPinCanCopyQuickSaveHideAndRestoreWithLockPreserved() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),session=CapturePinSession(store:.init(root:root.appendingPathComponent("pins"))),workspace=CaptureWorkspace(pinSession:session),board=NSPasteboard.withUniqueName()
        defer{workspace.shutdown();session.closeAll();board.releaseGlobally();try? FileManager.default.removeItem(at:root)}
        workspace.saving=CaptureSaveModel(read:{nil},write:{_ in})
        var options=CaptureSaveSettings();options.quick.directory=root.path;options.quick.template="locked";XCTAssertTrue(workspace.saving.apply(options))
        let id=try session.open(image()),editor=try XCTUnwrap(session.windows[id]),model=editor.model
        model.copyPasteboard=board;model.locked=true
        let before=try model.document.data();try workspace.perform(.copyImage);XCTAssertEqual(board.data(forType:.png),before)
        try workspace.perform(.quickSaveImage);XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:XCTUnwrap(model.savedImagePath))),before)
        XCTAssertFalse(editor.window?.isMovable ?? true)
        try workspace.perform(.hidePins);try workspace.perform(.showPin);XCTAssertTrue(model.locked)
        try session.flush();session.closeAll();workspace.shutdown()
        let restored=CapturePinSession(store:.init(root:root.appendingPathComponent("pins")));defer{restored.closeAll()}
        try restored.restore(id);let reopened=try XCTUnwrap(restored.windows[id])
        XCTAssertTrue(reopened.model.locked);XCTAssertFalse(reopened.window?.isMovable ?? true);XCTAssertEqual(try reopened.model.document.data(),before)
    }
    func testTypedContentUpdateCannotBypassTheSameLock() throws {
        _=NSApplication.shared
        let original=CapturePinContent.text(.init(plain:"Keep this")),model=CaptureEditorModel(image:try original.previewImage())
        model.pinContent=original;model.locked=true;let before=try model.document.data(),revision=model.revision
        XCTAssertThrowsError(try model.updatePinContent(.text(.init(plain:"Overwrite")))){self.pinLocked($0)}
        XCTAssertEqual(try model.document.data(),before);XCTAssertEqual(model.revision,revision);XCTAssertNil(model.pinContentSaveError)
        if case .text(let text)?=model.pinContent {XCTAssertEqual(text.plain,"Keep this")} else {XCTFail("Missing original content")}
        model.locked=false;try model.updatePinContent(.text(.init(plain:"Allowed")))
        if case .text(let text)?=model.pinContent {XCTAssertEqual(text.plain,"Allowed")} else {XCTFail("Missing updated content")}
        let html=CapturePinText(plain:"",html:"<b>Derived</b>")
        try model.updatePinContent(.text(html));model.locked=true
        var wrong=html;wrong.html="<b>Changed source</b>";wrong.plain="Changed source"
        XCTAssertThrowsError(try model.updatePinContent(.text(wrong),derivedHTMLText:true)){self.pinLocked($0)}
        var derived=html;derived.plain="Derived"
        try model.updatePinContent(.text(derived),derivedHTMLText:true)
        if case .text(let text)?=model.pinContent {XCTAssertEqual(text.html,html.html);XCTAssertEqual(text.plain,"Derived")} else {XCTFail("Missing derived text")}
    }
}
