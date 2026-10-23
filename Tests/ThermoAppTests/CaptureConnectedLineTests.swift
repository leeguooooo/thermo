import AppKit
import CaptureCore
import XCTest
@testable import ThermoApp

@MainActor final class CaptureConnectedLineTests:XCTestCase {
    private func fixture() throws -> (CaptureEditorModel,CaptureCanvas.Canvas) {
        _=NSApplication.shared
        let ctx=try XCTUnwrap(CGContext(data:nil,width:300,height:200,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        let m=CaptureEditorModel(image:try XCTUnwrap(ctx.makeImage()));m.chooseTool(.line);m.connectedLine=true
        let c=CaptureCanvas.Canvas(model:m);c.frame=CGRect(x:0,y:0,width:300,height:200);return (m,c)
    }
    private func mouse(_ type:NSEvent.EventType,_ x:Double,_ y:Double,clicks:Int=1,shift:Bool=false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with:type,location:CGPoint(x:x,y:y),modifierFlags:shift ? .shift : [],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:clicks,pressure:1))
    }
    private func click(_ c:CaptureCanvas.Canvas,_ x:Double,_ y:Double,clicks:Int=1,shift:Bool=false) throws {
        c.mouseDown(with:try mouse(.leftMouseDown,x,y,clicks:clicks,shift:shift));c.mouseUp(with:try mouse(.leftMouseUp,x,y,clicks:clicks,shift:shift))
    }
    private func key(_ c:CaptureCanvas.Canvas,_ code:UInt16) throws {c.keyDown(with:try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)))}
    func testClicksAndHoverRemainDraftUntilReturnThenOneUndoRemovesWholePolyline() throws {
        let (m,c)=try fixture();let rev=m.revision
        try click(c,20,20);c.mouseMoved(with:try mouse(.mouseMoved,80,30));XCTAssertEqual(c.draft?.points,[CGPoint(x:20,y:20),CGPoint(x:80,y:30)])
        try click(c,100,20);try click(c,100,150)
        XCTAssertTrue(m.document.annotations.isEmpty);XCTAssertEqual(m.revision,rev)
        m.annotationOptions.linePattern = .dashed
        try key(c,36);XCTAssertEqual(m.document.annotations[0].points,[CGPoint(x:20,y:20),CGPoint(x:100,y:20),CGPoint(x:100,y:150)])
        XCTAssertEqual(m.document.annotations[0].options.linePattern,.dashed);XCTAssertNil(c.draft)
        m.undoAnnotation();XCTAssertTrue(m.document.annotations.isEmpty);m.redoAnnotation();XCTAssertEqual(m.document.annotations[0].points.count,3)
    }
    func testDoubleClickDoesNotDuplicateEndpointAndRightClickFinishesConfirmedPoints() throws {
        let (m,c)=try fixture();try click(c,20,20);try click(c,100,20);try click(c,100,150);try click(c,100,150,clicks:2)
        XCTAssertEqual(m.document.annotations[0].points.count,3)
        try click(c,150,20);try click(c,250,20);c.mouseMoved(with:try mouse(.mouseMoved,280,150))
        c.rightMouseDown(with:try mouse(.rightMouseDown,280,150));XCTAssertEqual(m.document.annotations[1].points,[CGPoint(x:150,y:20),CGPoint(x:250,y:20)])
    }
    func testBackspaceAndEscapeDoNotRemoveExistingAnnotations() throws {
        let (m,c)=try fixture();m.document.append(.init(tool:.rectangle,points:[.zero,CGPoint(x:10,y:10)]))
        try click(c,20,20);try click(c,100,20);try click(c,100,150);try key(c,51)
        XCTAssertEqual(c.connectedLineVertices,[CGPoint(x:20,y:20),CGPoint(x:100,y:20)]);XCTAssertEqual(m.document.annotations.count,1)
        try key(c,53);XCTAssertNil(c.draft);XCTAssertEqual(m.document.annotations.count,1)
        try click(c,20,20);try key(c,51);XCTAssertTrue(c.connectedLineVertices.isEmpty);XCTAssertEqual(m.document.annotations.count,1)
    }
    func testToolLockModeDocumentAndOwnerChangesDiscardStaleDrafts() throws {
        let (m,c)=try fixture()
        for change in 0..<4 {
            m.locked=false;m.chooseTool(.line);m.connectedLine=true
            try click(c,20,20);try click(c,100,20)
            switch change {case 0:m.chooseTool(.arrow);case 1:m.locked=true;case 2:m.connectedLine=false;default:m.document.append(.init(tool:.rectangle,points:[.zero,CGPoint(x:10,y:10)]))}
            c.reconcileConnectedLine();XCTAssertNil(c.draft);try key(c,36)
            XCTAssertEqual(m.document.annotations.filter{$0.tool == .line}.count,0)
        }
        m.chooseTool(.line);m.connectedLine=true;try click(c,20,20);try click(c,100,20)
        let (other,_)=try fixture();c.model=other;c.finishConnectedLine();XCTAssertTrue(other.document.annotations.isEmpty);XCTAssertNil(c.draft)
    }
    func testInteriorVertexMovesAloneAndSupportsUndoAndAngleSnap() throws {
        let (m,c)=try fixture();m.document.append(.init(tool:.line,points:[CGPoint(x:20,y:20),CGPoint(x:100,y:20),CGPoint(x:100,y:150)]));m.chooseTool(.select);m.selectAnnotation(0)
        c.mouseDown(with:try mouse(.leftMouseDown,100,20));c.mouseDragged(with:try mouse(.leftMouseDragged,120,80,shift:true));c.mouseUp(with:try mouse(.leftMouseUp,120,80,shift:true))
        let points=m.document.annotations[0].points;XCTAssertEqual(points[0],CGPoint(x:20,y:20));XCTAssertEqual(points[2],CGPoint(x:100,y:150));XCTAssertEqual(points[1].x-20,points[1].y-20,accuracy:0.001)
        m.undoAnnotation();XCTAssertEqual(m.document.annotations[0].points[1],CGPoint(x:100,y:20))
    }
    func testShiftSnapsEachLegAndSinglePointCannotBeCommitted() throws {
        let (m,c)=try fixture();try click(c,20,20);try key(c,36);XCTAssertTrue(m.document.annotations.isEmpty)
        try click(c,100,25,shift:true);try click(c,100,150,shift:true);try key(c,36)
        let points=m.document.annotations[0].points;XCTAssertEqual(points[1].y,20,accuracy:0.001);XCTAssertEqual(points[2].x,points[1].x,accuracy:0.001)
    }
}
