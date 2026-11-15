import AppKit
import CaptureCore
import NativeFeatureAPI
import XCTest
@testable import CaptureFeature

@available(macOS 14,*)
@MainActor final class CapturePhysicalReadTests:XCTestCase {
    private actor ReadGate {
        var release:CheckedContinuation<Void,Never>?
        var ended=false
        func wait() async{if ended{return};await withCheckedContinuation{release=$0}}
        func finish(){ended=true;release?.resume();release=nil}
    }
    private final class OCRRead:@unchecked Sendable {
        let entered:XCTestExpectation
        let release=DispatchSemaphore(value:0)
        init(_ entered:XCTestExpectation){self.entered=entered}
        func recognize()->CaptureRecognition{entered.fulfill();_ = release.wait(timeout:.now()+4);return .init(text:"late result",codes:[])}
    }
    private func workspace(_ root:URL,_ flag:CaptureModuleTests.Flag)->CaptureWorkspace {
        let keys=CaptureModuleTests.Backend(),shortcuts=CaptureShortcutModel(backend:keys,read:{nil},write:{_ in},pinFocused:{false},execute:{_ in})
        let value=CaptureWorkspace(pinSession:.init(store:.init(root:root)),screenCaptureAccess:{XCTFail("no real screen access");return false},featureEnabled:{flag.on},shortcuts:shortcuts)
        value.saving=CaptureSaveModel(read:{nil},write:{_ in});return value
    }
    private func image()throws->CGImage {
        let context=try XCTUnwrap(CGContext(data:nil,width:4,height:4,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }
    func testCancelledSelectorStillOwnsItsPhysicalReadAndCallsCompletionOnce() async throws {
        _=NSApplication.shared
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-selector-read-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let flag=CaptureModuleTests.Flag();flag.on=true
        let workspace=workspace(root,flag),gate=ReadGate(),entered=expectation(description:"controlled display read");var completions=0
        defer{workspace.shutdown()}
        let selector=CaptureScreenshotSelector(captureDisplays:{entered.fulfill();await gate.wait();return []},work:workspace.captureReads)
        selector.start{_ in completions+=1}
        await fulfillment(of:[entered],timeout:2)
        selector.cancel();XCTAssertEqual(completions,1)
        XCTAssertTrue(workspace.captureBusy);XCTAssertThrowsError(try workspace.stopFeature())
        await gate.finish();await workspace.captureReads.finish()
        XCTAssertFalse(workspace.captureBusy);XCTAssertEqual(completions,1);XCTAssertNoThrow(try workspace.stopFeature())
    }
    func testOCRRemainsOwnedWithoutAPinWindowAndCannotPublishAfterRetirement() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-editor-read-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let flag=CaptureModuleTests.Flag();flag.on=true
        let workspace=workspace(root,flag),model=CaptureEditorModel(image:try image()),entered=expectation(description:"controlled OCR read"),read=OCRRead(entered)
        defer{read.release.signal();workspace.shutdown()}
        workspace.pinSession.configureEditor?(model)
        model.recognizeImage={_,_ in read.recognize()}
        model.recognize();await fulfillment(of:[entered],timeout:2)
        XCTAssertTrue(workspace.pinSession.windows.isEmpty);XCTAssertGreaterThan(workspace.editorWork.count,0)
        XCTAssertThrowsError(try workspace.stopFeature())
        flag.on=false;read.release.signal();await workspace.editorWork.finish()
        XCTAssertFalse(model.recognizing);XCTAssertEqual(model.recognition,"");XCTAssertNil(model.error)
    }
    func testEditorActionsHoldAdmissionAndStaleCopyLeavesPrivateBoardUntouched() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-editor-action-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let flag=CaptureModuleTests.Flag();flag.on=true
        let workspace=workspace(root,flag),model=CaptureEditorModel(image:try image())
        defer{workspace.shutdown()};workspace.pinSession.configureEditor?(model)
        var calls=0
        model.performUserAction{XCTAssertTrue(workspace.editorWork.hasOperations);XCTAssertThrowsError(try workspace.stopFeature());calls+=1}
        XCTAssertFalse(workspace.editorWork.hasOperations);XCTAssertEqual(calls,1)
        let board=NSPasteboard(name:.init("thermo-private-stale-copy-"+UUID().uuidString));board.setString("owned sentinel",forType:.string)
        defer{board.releaseGlobally()};model.copyPasteboard=board
        flag.on=false;model.performUserAction{calls+=1};model.copy()
        XCTAssertEqual(calls,1);XCTAssertEqual(board.string(forType:.string),"owned sentinel");XCTAssertThrowsError(try model.requireEditable())
    }
}
