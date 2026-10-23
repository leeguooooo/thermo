import AppKit
import CaptureCore
import XCTest
@testable import ThermoApp

@MainActor final class CaptureOCRSelectionTests:XCTestCase {
    private func fixture() throws -> (CaptureEditorModel,CaptureCanvas.Canvas) {
        _=NSApplication.shared
        let ctx=try XCTUnwrap(CGContext(data:nil,width:100,height:100,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        let model=CaptureEditorModel(image:try XCTUnwrap(ctx.makeImage()));model.recognition="A B\n世界"
        model.ocrSegments=[.init(range:NSRange(location:0,length:1),bounds:CGRect(x:0.1,y:0.7,width:0.1,height:0.1)),.init(range:NSRange(location:2,length:1),bounds:CGRect(x:0.4,y:0.7,width:0.1,height:0.1)),.init(range:NSRange(location:4,length:1),bounds:CGRect(x:0.1,y:0.4,width:0.1,height:0.1)),.init(range:NSRange(location:5,length:1),bounds:CGRect(x:0.3,y:0.4,width:0.1,height:0.1))]
        model.selectingOCRText=true
        let canvas=CaptureCanvas.Canvas(model:model);canvas.frame=CGRect(x:0,y:0,width:100,height:100);return(model,canvas)
    }
    private func event(_ kind:NSEvent.EventType,_ x:Double,_ y:Double,shift:Bool=false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with:kind,location:CGPoint(x:x,y:y),modifierFlags:shift ? .shift : [],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1))
    }
    func testDragAndShiftSelectionCopyOnlyChosenTextWithoutChangingImage() throws {
        let (model,canvas)=try fixture(),before=try model.document.data(),revision=model.revision,board=NSPasteboard.withUniqueName()
        defer{board.releaseGlobally()}
        canvas.mouseDown(with:try event(.leftMouseDown,5,65));canvas.mouseDragged(with:try event(.leftMouseDragged,55,85));canvas.mouseUp(with:try event(.leftMouseUp,55,85))
        XCTAssertEqual(model.selectedOCRText,"A B");XCTAssertTrue(model.copyOCRText(to:board));XCTAssertEqual(board.string(forType:.string),"A B")
        canvas.mouseDown(with:try event(.leftMouseDown,15,75,shift:true));canvas.mouseUp(with:try event(.leftMouseUp,15,75,shift:true));XCTAssertEqual(model.selectedOCRText,"B")
        canvas.mouseDown(with:try event(.leftMouseDown,15,45,shift:true));canvas.mouseUp(with:try event(.leftMouseUp,15,45,shift:true));XCTAssertEqual(model.selectedOCRText,"B\n世")
        XCTAssertEqual(model.revision,revision);XCTAssertEqual(try model.document.data(),before);XCTAssertNil(board.data(forType:.png))
        model.chooseTool(.rectangle);XCTAssertFalse(model.selectingOCRText);XCTAssertTrue(model.selectedOCRSegments.isEmpty)
    }
    func testZoomPanAndLockedPinKeepTextCoordinatesCorrect() throws {
        let (model,canvas)=try fixture();model.locked=true;model.zoom=2;model.pan=CGPoint(x:10,y:0)
        canvas.mouseDown(with:try event(.leftMouseDown,50,94));canvas.mouseUp(with:try event(.leftMouseUp,50,94))
        XCTAssertEqual(model.selectedOCRText,"B");XCTAssertTrue(model.document.annotations.isEmpty)
    }
    func testAccessibleTextRegionsToggleSelectionAndRejectStaleGeometry() throws {
        let (model,canvas)=try fixture()
        let children=try XCTUnwrap(canvas.accessibilityChildren() as? [CaptureOCRAccessibilityElement])
        XCTAssertEqual(children.count,4);XCTAssertEqual(children[1].accessibilityLabel(),"B")
        XCTAssertTrue(children[1].isAccessibilityElement());XCTAssertTrue(children[1].isAccessibilityEnabled())
        XCTAssertTrue(children[1].accessibilityPerformPress());XCTAssertEqual(model.selectedOCRText,"B")
        XCTAssertTrue(children[1].accessibilityPerformPress());XCTAssertTrue(model.selectedOCRText.isEmpty)
        model.recognition="Edited";XCTAssertFalse(children[1].accessibilityPerformPress());XCTAssertTrue(canvas.accessibilityChildren()?.isEmpty == true)
    }
    func testEditingRecognizedTextOrImageInvalidatesGeometryAndEmptyCopyPreservesClipboard() throws {
        let (model,_)=try fixture(),board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()}
        model.selectedOCRSegments=[0];model.recognition="Edited"
        XCTAssertTrue(model.ocrSegments.isEmpty);XCTAssertTrue(model.selectedOCRSegments.isEmpty);XCTAssertFalse(model.selectingOCRText)
        model.recognition="";board.setString("sentinel",forType:.string);XCTAssertFalse(model.copyOCRText(to:board));XCTAssertEqual(board.string(forType:.string),"sentinel")
        model.recognition="Old";model.ocrSegments=[.init(range:NSRange(location:0,length:3),bounds:CGRect(x:0,y:0,width:1,height:1))];model.selectingOCRText=true
        model.document.append(.init(tool:.redact,points:[.zero,CGPoint(x:30,y:30)]))
        XCTAssertTrue(model.recognition.isEmpty);XCTAssertTrue(model.ocrSegments.isEmpty);XCTAssertFalse(model.selectingOCRText)
        model.copyPasteboard=board;model.recognition="Private OCR copy"
        XCTAssertTrue(model.copyOCRText());XCTAssertEqual(board.string(forType:.string),"Private OCR copy")
        model.copy();XCTAssertNotNil(board.data(forType:.png))
    }
}
