import AppKit
import CaptureCore
import CaptureScriptCore
import XCTest
@testable import ThermoApp

@MainActor final class CaptureGeometryActionTests:XCTestCase {
    private func image() throws -> CGImage {
        _=NSApplication.shared
        let c=try XCTUnwrap(CGContext(data:nil,width:80,height:60,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        c.setFillColor(NSColor.red.cgColor);c.fill(CGRect(x:0,y:0,width:80,height:20));c.setFillColor(NSColor.blue.cgColor);c.fill(CGRect(x:0,y:20,width:30,height:40));return try XCTUnwrap(c.makeImage())
    }
    private func worker() throws -> URL {
        var folder=Bundle(for:Self.self).bundleURL
        for _ in 0..<8 {let candidate=folder.appendingPathComponent("thermo-capture-script");if FileManager.default.isExecutableFile(atPath:candidate.path){return candidate};folder.deleteLastPathComponent()};throw CaptureScriptFailure.unavailable
    }
    func testScriptDirectionsPersistAndRejectLockedAndTypedEdits() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("geometry-action-"+UUID().uuidString),session=CapturePinSession(store:.init(root:root)),workspace=CaptureWorkspace(pinSession:session),board=NSPasteboard.withUniqueName()
        defer{workspace.shutdown();session.closeAll();board.releaseGlobally();try? FileManager.default.removeItem(at:root)}
        workspace.scriptWorker=try worker();workspace.scriptPasteboard=board
        let id=try session.open(image()),model=try XCTUnwrap(session.windows[id]?.model)
        var expected=model.document;try expected.transform(.rotateCounterclockwise);try expected.transform(.flipVertical)
        for action in [CaptureAction.rotateLeft,.flipVertical] {XCTAssertTrue(action.needsPin && action.imageOnly && action.requiresUnlockedPin && action.supportsScript)}
        _=try await workspace.executeScript("thermo.perform('rotateLeft');thermo.perform('flipVertical');thermo.perform('copyImage');")
        XCTAssertEqual(board.data(forType:.png),try expected.data());XCTAssertEqual(model.document.size,CGSize(width:60,height:80))
        let fresh=CapturePinLibraryStore(root:root),loaded=try fresh.load(),pin=try XCTUnwrap(loaded.pins.first{$0.id==id});XCTAssertEqual(try fresh.document(for:pin).data(),try expected.data())
        model.locked=true
        for operation in [CaptureImageTransform.rotateCounterclockwise,.flipVertical] {XCTAssertThrowsError(try model.transformImage(operation))}
        let result=try await workspace.executeScript("let rejected=0;for(const action of ['rotateLeft','flipVertical']){try{thermo.perform(action)}catch(e){rejected++}}return rejected;")
        XCTAssertEqual(result.value,.number(2));XCTAssertEqual(try model.document.data(),try expected.data())
        model.locked=false;model.pinContent = .text(.init(plain:"typed"));XCTAssertThrowsError(try model.transformImage(.flipVertical))
        model.pinContent=nil
    }
}
