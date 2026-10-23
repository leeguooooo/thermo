import AppKit
import CaptureCore
import XCTest
@testable import ThermoApp

@MainActor final class CaptureSequenceEditingTests:XCTestCase {
    private func fixture() throws -> (CaptureEditorModel,CaptureCanvas.Canvas) {
        _=NSApplication.shared
        let ctx=try XCTUnwrap(CGContext(data:nil,width:300,height:200,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        let model=CaptureEditorModel(image:try XCTUnwrap(ctx.makeImage()));let canvas=CaptureCanvas.Canvas(model:model);canvas.frame=CGRect(x:0,y:0,width:300,height:200)
        return (model,canvas)
    }
    private func event(_ type:NSEvent.EventType,_ x:Double,_ y:Double,shift:Bool=false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with:type,location:CGPoint(x:x,y:y),modifierFlags:shift ? .shift : [],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1))
    }
    private func click(_ c:CaptureCanvas.Canvas) throws {c.mouseDown(with:try event(.leftMouseDown,50,50));c.mouseUp(with:try event(.leftMouseUp,50,50))}
    func testStartValueFormatAndDeletionDoNotReuseExistingNumber() throws {
        let (m,c)=try fixture();m.chooseTool(.number);m.nextSequenceNumber=26;m.annotationOptions.numberFormat = .alphabetic
        try click(c);try click(c);XCTAssertEqual(m.document.annotations.map(\.numberLabel),["Z","AA"]);XCTAssertEqual(m.nextSequenceNumber,28)
        m.selectAnnotation(0);m.deleteSelected();try click(c);XCTAssertEqual(m.document.annotations.map(\.numberLabel),["AA","AB"])
        m.undoAnnotation();XCTAssertEqual(m.document.annotations.map(\.numberLabel),["AA"]);XCTAssertEqual(m.nextSequenceNumber,29)
        m.chooseTool(.move);m.chooseTool(.number);XCTAssertEqual(m.nextSequenceNumber,29)
    }
    func testNumberStyleEditUndoAndLockedProtection() throws {
        let (m,c)=try fixture();m.chooseTool(.number);try click(c);m.selectAnnotation(0)
        m.annotationOptions.numberValue=49;m.annotationOptions.numberFormat = .roman;m.annotationOptions.numberShape = .square;m.applySelectedStyle()
        XCTAssertEqual(m.document.annotations[0].numberLabel,"XLIX");m.undoAnnotation();XCTAssertEqual(m.document.annotations[0].numberLabel,"1")
        m.redoAnnotation();XCTAssertEqual(m.annotationOptions.numberValue,49)
        m.locked=true;m.annotationOptions.numberValue=10;m.applySelectedStyle();XCTAssertEqual(m.document.annotations[0].numberLabel,"XLIX")
        try click(c);XCTAssertEqual(m.document.annotations.count,1)
    }
    func testShiftArrowSnapsAndDraggedNumberKeepsItsLeader() throws {
        let (m,c)=try fixture();m.chooseTool(.arrow)
        c.mouseDown(with:try event(.leftMouseDown,20,20));c.mouseDragged(with:try event(.leftMouseDragged,100,30,shift:true));c.mouseUp(with:try event(.leftMouseUp,100,30,shift:true))
        XCTAssertEqual(m.document.annotations[0].points.last?.y,20)
        m.chooseTool(.number);c.mouseDown(with:try event(.leftMouseDown,50,50));c.mouseDragged(with:try event(.leftMouseDragged,150,150));c.mouseUp(with:try event(.leftMouseUp,150,150))
        XCTAssertEqual(m.document.annotations[1].points,[CGPoint(x:50,y:50),CGPoint(x:150,y:150)])
        m.nextSequenceNumber=4000;try click(c);XCTAssertEqual(m.document.annotations.count,2);XCTAssertNotNil(m.error)
    }
    func testLegacyFreeTextCannotOverflowTheNextSequenceCounter() throws {
        let (m,_)=try fixture()
        m.document.append(.init(tool:.number,points:[CGPoint(x:50,y:50)],text:String(Int.max)))
        m.chooseTool(.number);XCTAssertEqual(m.nextSequenceNumber,1)
        m.nextSequenceNumber=3999
        m.chooseTool(.move);m.chooseTool(.number);XCTAssertEqual(m.nextSequenceNumber,3999)
    }
}
