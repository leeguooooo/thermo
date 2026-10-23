import AppKit
import CaptureCore
import XCTest
@testable import ThermoApp

@MainActor final class CaptureArrowEditingTests:XCTestCase {
    private func fixture() throws -> (CaptureEditorModel,CaptureCanvas.Canvas) {
        _=NSApplication.shared
        let ctx=try XCTUnwrap(CGContext(data:nil,width:300,height:200,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        let m=CaptureEditorModel(image:try XCTUnwrap(ctx.makeImage()))
        m.document.append(.init(tool:.arrow,points:[CGPoint(x:40,y:40),CGPoint(x:240,y:40)]));m.tool = .select;m.selectAnnotation(0)
        let c=CaptureCanvas.Canvas(model:m);c.frame=CGRect(x:0,y:0,width:300,height:200);return (m,c)
    }
    private func event(_ type:NSEvent.EventType,_ x:Double,_ y:Double,shift:Bool=false,clicks:Int=1) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with:type,location:CGPoint(x:x,y:y),modifierFlags:shift ? .shift : [],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:clicks,pressure:1))
    }
    private func drag(_ c:CaptureCanvas.Canvas,_ a:CGPoint,_ b:CGPoint,shift:Bool=false) throws {
        c.mouseDown(with:try event(.leftMouseDown,a.x,a.y));c.mouseDragged(with:try event(.leftMouseDragged,b.x,b.y,shift:shift));c.mouseUp(with:try event(.leftMouseUp,b.x,b.y,shift:shift))
    }
    func testEachEndpointChangesOnlyItselfAndCommitsOneUndoStep() throws {
        let (m,c)=try fixture();let original=m.document.annotations[0].points
        c.mouseDown(with:try event(.leftMouseDown,240,40));c.mouseDragged(with:try event(.leftMouseDragged,220,100))
        XCTAssertEqual(m.document.annotations[0].points,original);XCTAssertEqual(c.selectionPreview[0]?.points,[original[0],CGPoint(x:220,y:100)])
        c.mouseUp(with:try event(.leftMouseUp,220,100));XCTAssertEqual(m.document.annotations[0].points,[original[0],CGPoint(x:220,y:100)])
        m.undoAnnotation();XCTAssertEqual(m.document.annotations[0].points,original)
        m.redoAnnotation();XCTAssertEqual(m.document.annotations[0].points.last,CGPoint(x:220,y:100))
        try drag(c,original[0],CGPoint(x:60,y:80));XCTAssertEqual(m.document.annotations[0].points,[CGPoint(x:60,y:80),CGPoint(x:220,y:100)])
    }
    func testEndpointSnapZoomPanAndBodyMoveRemainInImageCoordinates() throws {
        let (m,c)=try fixture()
        m.document.replaceAnnotation(at:0,with:.init(tool:.arrow,points:[CGPoint(x:100,y:80),CGPoint(x:180,y:80)]));m.selectAnnotation(0)
        m.zoom=2;m.pan=CGPoint(x:10,y:5)
        // At 2x zoom the image origin is (-140,-95).
        try drag(c,CGPoint(x:140,y:65),CGPoint(x:160,y:105))
        XCTAssertEqual(m.document.annotations[0].points,[CGPoint(x:110,y:100),CGPoint(x:190,y:100)])
        try drag(c,CGPoint(x:240,y:105),CGPoint(x:220,y:165),shift:true)
        let item=m.document.annotations[0];let a=item.points[0],b=item.points[1]
        XCTAssertEqual(abs(b.x-a.x),abs(b.y-a.y),accuracy:0.001);XCTAssertEqual(a,CGPoint(x:110,y:100))
    }
    func testLockedStaleAndEscapeGesturesCannotCommit() throws {
        let (m,c)=try fixture();let original=m.document.annotations[0].points
        c.mouseDown(with:try event(.leftMouseDown,240,40));c.mouseDragged(with:try event(.leftMouseDragged,230,80));m.locked=true
        XCTAssertEqual(try NSBitmapImageRep(cgImage:c.renderedImage()).representation(using:.png,properties:[:]),try m.document.data())
        c.mouseUp(with:try event(.leftMouseUp,230,80));XCTAssertEqual(m.document.annotations[0].points,original)
        m.locked=false;c.mouseDown(with:try event(.leftMouseDown,240,40));c.mouseDragged(with:try event(.leftMouseDragged,230,80))
        m.document.append(.init(tool:.line,points:[CGPoint(x:20,y:150),CGPoint(x:200,y:150)]));c.mouseUp(with:try event(.leftMouseUp,230,80));XCTAssertEqual(m.document.annotations[0].points,original)
        c.mouseDown(with:try event(.leftMouseDown,240,40));c.mouseDragged(with:try event(.leftMouseDragged,230,80))
        let esc=try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:53));c.keyDown(with:esc);c.mouseUp(with:try event(.leftMouseUp,230,80));XCTAssertEqual(m.document.annotations[0].points,original)
    }
    func testDoubleClickRequestsCommentAndCommentEditIsUndoableAndLocked() throws {
        let (m,c)=try fixture();let token=m.arrowCommentEditingID,rev=m.revision
        c.mouseDown(with:try event(.leftMouseDown,150,40,clicks:2));c.mouseUp(with:try event(.leftMouseUp,150,40,clicks:2))
        XCTAssertNotEqual(m.arrowCommentEditingID,token);XCTAssertEqual(m.revision,rev)
        m.annotationOptions.arrowComment="Check this button";m.applySelectedStyle();XCTAssertEqual(m.document.annotations[0].options.arrowComment,"Check this button")
        m.undoAnnotation();XCTAssertEqual(m.annotationOptions.arrowComment,"");m.redoAnnotation();XCTAssertEqual(m.annotationOptions.arrowComment,"Check this button")
        m.locked=true;m.annotationOptions.arrowComment="blocked";m.applySelectedStyle();XCTAssertEqual(m.document.annotations[0].options.arrowComment,"Check this button")
    }
    func testNewArrowDoesNotInheritPreviousArrowsComment() throws {
        let (m,c)=try fixture();m.annotationOptions.arrowComment="Existing comment";m.applySelectedStyle();m.chooseTool(.arrow)
        c.mouseDown(with:try event(.leftMouseDown,50,130));c.mouseDragged(with:try event(.leftMouseDragged,200,130));c.mouseUp(with:try event(.leftMouseUp,200,130))
        XCTAssertEqual(m.document.annotations[0].options.arrowComment,"Existing comment");XCTAssertEqual(m.document.annotations[1].options.arrowComment,"")
    }
}
