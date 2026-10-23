import AppKit
import CaptureCore
import XCTest
@testable import ThermoApp

@MainActor final class CaptureCropEditingTests:XCTestCase {
    private func fixture() throws -> (CaptureEditorModel,CaptureCanvas.Canvas) {
        _=NSApplication.shared
        let ctx=try XCTUnwrap(CGContext(data:nil,width:100,height:80,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(NSColor.red.cgColor);ctx.fill(CGRect(x:0,y:0,width:100,height:40))
        ctx.setFillColor(NSColor.blue.cgColor);ctx.fill(CGRect(x:0,y:40,width:100,height:40))
        let model=CaptureEditorModel(image:try XCTUnwrap(ctx.makeImage()));model.tool = .crop
        let canvas=CaptureCanvas.Canvas(model:model);canvas.frame=CGRect(x:0,y:0,width:100,height:80)
        return (model,canvas)
    }
    private func mouse(_ type:NSEvent.EventType,_ x:Double,_ y:Double) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with:type,location:CGPoint(x:x,y:y),modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1))
    }
    private func key(_ code:UInt16,_ flags:NSEvent.ModifierFlags=[]) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code))
    }
    private func drag(_ canvas:CaptureCanvas.Canvas,_ a:CGPoint,_ b:CGPoint) throws {
        canvas.mouseDown(with:try mouse(.leftMouseDown,a.x,a.y));canvas.mouseDragged(with:try mouse(.leftMouseDragged,b.x,b.y));canvas.mouseUp(with:try mouse(.leftMouseUp,b.x,b.y))
    }
    func testDragPreviewsMoveResizeAndKeyboardCommitUseSingleUndo() throws {
        let (m,c)=try fixture();m.document.append(.init(tool:.rectangle,points:[.zero,CGPoint(x:5,y:5)]));let rev=m.revision
        try drag(c,CGPoint(x:10,y:10),CGPoint(x:50,y:40))
        XCTAssertEqual(m.cropSelection,CGRect(x:10,y:10,width:40,height:30));XCTAssertEqual(m.revision,rev)
        try drag(c,CGPoint(x:20,y:20),CGPoint(x:25,y:25))
        XCTAssertEqual(m.cropSelection,CGRect(x:15,y:15,width:40,height:30))
        try drag(c,CGPoint(x:55,y:45),CGPoint(x:65,y:55))
        XCTAssertEqual(m.cropSelection,CGRect(x:15,y:15,width:50,height:40))
        c.keyDown(with:try key(124));c.keyDown(with:try key(126,.shift))
        XCTAssertEqual(m.cropSelection,CGRect(x:16,y:25,width:50,height:40))
        c.keyDown(with:try key(36));XCTAssertEqual(m.document.size,CGSize(width:50,height:40));XCTAssertNil(m.cropSelection);XCTAssertTrue(m.document.annotations.isEmpty)
        m.undoAnnotation();XCTAssertEqual(m.document.size,CGSize(width:100,height:80));XCTAssertEqual(m.document.annotations.count,1)
        m.redoAnnotation();XCTAssertEqual(m.document.size,CGSize(width:50,height:40))
    }
    func testCancelToolLockAndImageChangesDiscardSelectionWithoutMutatingImage() throws {
        let (m,c)=try fixture();let rev=m.revision
        m.setCropSelection(CGRect(x:10,y:10,width:20,height:20));c.keyDown(with:try key(53));XCTAssertNil(m.cropSelection);XCTAssertEqual(m.revision,rev)
        m.setCropSelection(CGRect(x:10,y:10,width:20,height:20));m.chooseTool(.move);XCTAssertNil(m.cropSelection)
        m.tool = .crop;m.setCropSelection(CGRect(x:10,y:10,width:20,height:20));m.locked=true;XCTAssertNil(m.cropSelection)
        m.setCropSelection(CGRect(x:10,y:10,width:20,height:20));m.commitCrop();XCTAssertEqual(m.revision,rev)
        m.locked=false;m.setCropSelection(CGRect(x:10,y:10,width:20,height:20));m.document.append(.init(tool:.line,points:[.zero,CGPoint(x:5,y:5)]));XCTAssertNil(m.cropSelection)
    }
    func testPreciseDimensionsClampToImageAndMovementKeepsSize() throws {
        let (m,c)=try fixture();m.setCropSelection(CGRect(x:10.2,y:20.7,width:30.1,height:20.1))
        XCTAssertEqual(m.cropSelection,CGRect(x:10,y:20,width:31,height:21))
        m.resizeCrop(width:17,height:13);XCTAssertEqual(m.cropSelection?.size,CGSize(width:17,height:13))
        for _ in 0..<20 {c.keyDown(with:try key(124,.shift));c.keyDown(with:try key(126,.shift))}
        XCTAssertEqual(m.cropSelection,CGRect(x:83,y:67,width:17,height:13))
        m.resizeCrop(width:1000,height:0);XCTAssertEqual(m.cropSelection,CGRect(x:83,y:67,width:17,height:1))
        m.resizeCrop(width:.nan);XCTAssertEqual(m.cropSelection?.width,17)
        m.setCropSelection(.zero);XCTAssertNil(m.cropSelection)
    }
    func testStaleGestureCannotCreateCropAndZoomUsesImagePixels() throws {
        let (m,c)=try fixture()
        c.mouseDown(with:try mouse(.leftMouseDown,10,10));c.mouseDragged(with:try mouse(.leftMouseDragged,40,40));m.document.append(.init(tool:.line,points:[.zero,CGPoint(x:5,y:5)]));c.mouseUp(with:try mouse(.leftMouseUp,40,40));XCTAssertNil(m.cropSelection)
        m.zoom=2;m.pan=CGPoint(x:10,y:5)
        // Image origin is (-40,-35), so these view coordinates select (25,20)...(45,30).
        try drag(c,CGPoint(x:10,y:5),CGPoint(x:50,y:25));XCTAssertEqual(m.cropSelection,CGRect(x:25,y:20,width:20,height:10))
        c.keyDown(with:try key(124));XCTAssertEqual(m.cropSelection?.minX,26)
    }
}
