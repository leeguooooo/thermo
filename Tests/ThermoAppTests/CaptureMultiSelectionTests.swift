import AppKit
import CaptureCore
import XCTest
@testable import ThermoApp

@MainActor final class CaptureMultiSelectionTests:XCTestCase {
    private func fixture() throws -> (CaptureEditorModel,CaptureCanvas.Canvas) {
        _=NSApplication.shared
        let ctx=try XCTUnwrap(CGContext(data:nil,width:100,height:100,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        let model=CaptureEditorModel(image:try XCTUnwrap(ctx.makeImage()))
        for x in [10,35,70] {model.document.append(.init(tool:.rectangle,points:[CGPoint(x:x,y:10),CGPoint(x:x+10,y:20)]))}
        model.tool = .select
        let canvas=CaptureCanvas.Canvas(model:model);canvas.frame=CGRect(x:0,y:0,width:100,height:100)
        return (model,canvas)
    }
    private func event(_ kind:NSEvent.EventType,_ x:Double,_ y:Double,shift:Bool=false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with:kind,location:CGPoint(x:x,y:y),modifierFlags:shift ? .shift : [],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1))
    }
    func testMarqueeMovesBothObjectsAndOneUndoRestoresTheWholeGroup() throws {
        let (model,canvas)=try fixture()
        canvas.mouseDown(with:try event(.leftMouseDown,0,0));canvas.mouseDragged(with:try event(.leftMouseDragged,50,27));canvas.mouseUp(with:try event(.leftMouseUp,50,27))
        XCTAssertEqual(model.selectedAnnotations,[0,1]);XCTAssertNil(model.selectedAnnotation)
        canvas.mouseDown(with:try event(.leftMouseDown,15,15));canvas.mouseDragged(with:try event(.leftMouseDragged,25,30))
        XCTAssertEqual(model.document.annotations[0].points[0],CGPoint(x:10,y:10),"Preview must not edit the source")
        canvas.mouseUp(with:try event(.leftMouseUp,25,30))
        XCTAssertEqual(model.document.annotations[0].points[0],CGPoint(x:20,y:25));XCTAssertEqual(model.document.annotations[1].points[0],CGPoint(x:45,y:25))
        XCTAssertEqual(model.document.annotations[2].points[0],CGPoint(x:70,y:10))
        model.undoAnnotation();XCTAssertEqual(model.document.annotations[0].points[0],CGPoint(x:10,y:10));XCTAssertEqual(model.document.annotations[1].points[0],CGPoint(x:35,y:10));XCTAssertEqual(model.selectedAnnotations,[0,1])
        model.redoAnnotation();XCTAssertEqual(model.document.annotations[1].points[0],CGPoint(x:45,y:25))
    }
    func testShiftToggleAndWholeGroupDeleteAreUndoableWithoutChangingOtherObjects() throws {
        let (model,canvas)=try fixture()
        for (x,shift) in [(15.0,false),(40.0,true)] {canvas.mouseDown(with:try event(.leftMouseDown,x,15,shift:shift));canvas.mouseUp(with:try event(.leftMouseUp,x,15,shift:shift))}
        XCTAssertEqual(model.selectedAnnotations,[0,1])
        canvas.mouseDown(with:try event(.leftMouseDown,15,15,shift:true));canvas.mouseUp(with:try event(.leftMouseUp,15,15,shift:true))
        XCTAssertEqual(model.selectedAnnotations,[1]);XCTAssertEqual(model.lineWidth,4)
        model.selectAnnotations([0,1]);model.deleteSelected();XCTAssertEqual(model.document.annotations.count,1);XCTAssertEqual(model.document.annotations[0].points[0].x,70);XCTAssertTrue(model.selectedAnnotations.isEmpty)
        model.undoAnnotation();XCTAssertEqual(model.document.annotations.count,3)
    }
    func testGroupCornerResizeUsesOneSharedOriginAndSingleUndo() throws {
        let (model,canvas)=try fixture();model.selectAnnotations([0,1])
        canvas.mouseDown(with:try event(.leftMouseDown,47,22));canvas.mouseDragged(with:try event(.leftMouseDragged,86,36));canvas.mouseUp(with:try event(.leftMouseUp,86,36))
        XCTAssertEqual(model.document.annotations[0].points[0],CGPoint(x:12,y:12))
        XCTAssertEqual(model.document.annotations[1].points[0],CGPoint(x:62,y:12))
        model.undoAnnotation();XCTAssertEqual(model.document.annotations[0].points[0],CGPoint(x:10,y:10));XCTAssertEqual(model.document.annotations[1].points[0],CGPoint(x:35,y:10))
    }
    func testClickWithoutDragDoesNotCreateUndoAndStaleOrLockedDragCannotCommit() throws {
        let (model,canvas)=try fixture()
        canvas.mouseDown(with:try event(.leftMouseDown,15,15));canvas.mouseUp(with:try event(.leftMouseUp,15,15))
        model.undoAnnotation();XCTAssertEqual(model.document.annotations.count,2,"A selection click must not consume an undo step")
        model.selectAnnotations([0,1]);canvas.mouseDown(with:try event(.leftMouseDown,15,15));canvas.mouseDragged(with:try event(.leftMouseDragged,25,25))
        model.document.append(.init(tool:.ellipse,points:[CGPoint(x:80,y:80),CGPoint(x:90,y:90)]))
        canvas.mouseUp(with:try event(.leftMouseUp,25,25));XCTAssertEqual(model.document.annotations[0].points[0],CGPoint(x:10,y:10));XCTAssertEqual(model.document.annotations.count,3)
        model.locked=true;model.deleteSelected();XCTAssertEqual(model.document.annotations.count,3)
        canvas.mouseDown(with:try event(.leftMouseDown,15,15));canvas.mouseDragged(with:try event(.leftMouseDragged,25,25));canvas.mouseUp(with:try event(.leftMouseUp,25,25));XCTAssertEqual(model.document.annotations[0].points[0],CGPoint(x:10,y:10))
    }
    func testShiftMarqueeAddsAndSingleSelectionRefreshesInspector() throws {
        let (model,canvas)=try fixture();model.selectAnnotation(2)
        canvas.mouseDown(with:try event(.leftMouseDown,0,0,shift:true));canvas.mouseDragged(with:try event(.leftMouseDragged,27,27,shift:true));canvas.mouseUp(with:try event(.leftMouseUp,27,27,shift:true))
        XCTAssertEqual(model.selectedAnnotations,[0,2])
        model.selectAllAnnotations();XCTAssertEqual(model.selectedAnnotations,[0,1,2])
        model.selectAnnotations([99]);XCTAssertTrue(model.selectedAnnotations.isEmpty)
    }
}
