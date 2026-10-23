import AppKit
import CaptureCore
import CaptureScriptCore
import XCTest
@testable import ThermoApp

@MainActor final class CaptureImageAdjustmentActionTests:XCTestCase {
    private func image() throws -> CGImage {
        _=NSApplication.shared
        let c=try XCTUnwrap(CGContext(data:nil,width:80,height:60,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue));c.setFillColor(NSColor.red.cgColor);c.fill(CGRect(x:0,y:0,width:80,height:60));return try XCTUnwrap(c.makeImage())
    }
    private func worker() throws -> URL {
        var folder=Bundle(for:Self.self).bundleURL
        for _ in 0..<8 {let candidate=folder.appendingPathComponent("thermo-capture-script");if FileManager.default.isExecutableFile(atPath:candidate.path){return candidate};folder.deleteLastPathComponent()};throw CaptureScriptFailure.unavailable
    }
    func testActionsClampAndAvoidNoOpRevisionsAndRejectLockedOrTypedEdits() throws {
        let m=CaptureEditorModel(image:try image())
        for _ in 0..<20 {try m.applyColorAction(.brightnessUp)};XCTAssertEqual(m.document.imageAdjustments.brightness,2);let rev=m.revision
        try m.applyColorAction(.brightnessUp);XCTAssertEqual(m.revision,rev)
        try m.applyColorAction(.resetImageAdjustments);XCTAssertTrue(m.document.imageAdjustments.isDefault);m.undoAnnotation();XCTAssertEqual(m.document.imageAdjustments.brightness,2)
        m.locked=true;let before=try m.document.data()
        for action in [CaptureAction.grayscale,.invert,.brightnessUp,.brightnessDown,.resetImageAdjustments] {
            XCTAssertTrue(action.needsPin && action.imageOnly && action.requiresUnlockedPin && action.supportsScript)
            XCTAssertThrowsError(try m.applyColorAction(action))
        };XCTAssertEqual(try m.document.data(),before)
        m.locked=false;m.pinContent = .text(.init(plain:"typed"));XCTAssertThrowsError(try m.applyColorAction(.grayscale))
    }
    func testScriptActionsUseTheSamePinChecksAndPersistParametersAndCopyPixels() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("color-action-"+UUID().uuidString),session=CapturePinSession(store:.init(root:root)),workspace=CaptureWorkspace(pinSession:session),board=NSPasteboard.withUniqueName()
        defer{workspace.shutdown();session.closeAll();board.releaseGlobally();try? FileManager.default.removeItem(at:root)}
        workspace.scriptWorker=try worker();workspace.scriptPasteboard=board
        let id=try session.open(image()),m=try XCTUnwrap(session.windows[id]?.model),base=try m.document.data()
        _=try await workspace.executeScript("thermo.perform('grayscale');thermo.perform('invert');thermo.perform('brightnessUp');thermo.perform('brightnessDown');thermo.perform('resetImageAdjustments');thermo.perform('copyImage');")
        XCTAssertEqual(board.data(forType:.png),base);XCTAssertTrue(m.document.imageAdjustments.isDefault)
        _=try await workspace.executeScript("thermo.perform('grayscale');thermo.perform('brightnessUp');thermo.perform('copyImage');")
        let fresh=CapturePinLibraryStore(root:root),loaded=try fresh.load(),pin=try XCTUnwrap(loaded.pins.first(where:{$0.id==id})),restored=try fresh.document(for:pin)
        XCTAssertEqual(restored.imageAdjustments,.init(grayscale:true,brightness:1.1));XCTAssertEqual(try restored.data(),board.data(forType:.png))
        m.locked=true
        let result=try await workspace.executeScript("try{thermo.perform('invert');return false}catch(e){return true}")
        XCTAssertEqual(result.value,.bool(true));XCTAssertFalse(m.document.imageAdjustments.inverted)
    }
}
