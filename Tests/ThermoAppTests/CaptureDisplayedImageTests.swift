import AppKit
import CaptureCore
import XCTest
@testable import ThermoApp

@MainActor final class CaptureDisplayedImageTests:XCTestCase {
    private func fixture() throws -> (CaptureEditorModel,CaptureCanvas.Canvas,NSPasteboard) {
        _=NSApplication.shared
        let c=try XCTUnwrap(CGContext(data:nil,width:200,height:100,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue));c.setFillColor(NSColor.blue.cgColor);c.fill(CGRect(x:0,y:0,width:200,height:100))
        let m=CaptureEditorModel(image:try XCTUnwrap(c.makeImage())),v=CaptureCanvas.Canvas(model:m),board=NSPasteboard.withUniqueName()
        m.copyPasteboard=board;v.frame=CGRect(x:0,y:0,width:100,height:80);m.zoom=0.5;m.opacity=0.5;return(m,v,board)
    }
    private func copied(_ board:NSPasteboard) throws -> NSBitmapImageRep {try XCTUnwrap(NSBitmapImageRep(data:try XCTUnwrap(board.data(forType:.png))))}
    func testCopyModesHaveDistinctSizesAndOpacityWithoutMutatingHistoryIncludingLockedPins() throws {
        let (m,v,b)=try fixture();defer{b.releaseGlobally()};try withExtendedLifetime(v) {
            let rev=m.revision;m.locked=true;m.copy()
            XCTAssertEqual(try copied(b).pixelsWide,200);XCTAssertEqual(try copied(b).colorAt(x:0,y:0)?.alphaComponent,1)
            m.copyDisplayedImage();XCTAssertEqual(try copied(b).pixelsWide,50);XCTAssertEqual(try copied(b).pixelsHigh,25);XCTAssertEqual(try copied(b).colorAt(x:0,y:0)!.alphaComponent,0.5,accuracy:0.01)
            XCTAssertEqual(m.revision,rev);XCTAssertFalse(m.document.canUndo)
        }
    }
    func testGeometryFollowsViewResizingZoomAndEditedDocumentRatherThanAStaleScale() throws {
        let (m,v,b)=try fixture();defer{b.releaseGlobally()}
        v.frame=CGRect(x:0,y:0,width:800,height:400)
        XCTAssertEqual(try m.displayedDocument().size,CGSize(width:400,height:200))
        m.zoom=0.25;try m.document.crop(to:CGRect(x:0,y:0,width:100,height:50))
        XCTAssertEqual(try m.displayedDocument().size,CGSize(width:200,height:100));m.copy();XCTAssertEqual(try copied(b).pixelsWide,100)
        withExtendedLifetime(v){}
    }
    func testReboundOrReleasedCanvasCannotSupplyAnotherModelsDisplayGeometryAndFailurePreservesClipboard() throws {
        let (m,v,b)=try fixture();defer{b.releaseGlobally()};b.setString("keep me",forType:.string)
        let (other,otherView,otherBoard)=try fixture();defer{otherBoard.releaseGlobally()}
        v.model=other;XCTAssertThrowsError(try m.displayedDocument());m.copyDisplayedImage();XCTAssertEqual(b.string(forType:.string),"keep me")
        withExtendedLifetime(otherView) {XCTAssertNotNil(other.imageDisplayScale?())}
        var temporary:CaptureCanvas.Canvas?=CaptureCanvas.Canvas(model:m);temporary?.frame=CGRect(x:0,y:0,width:100,height:80)
        weak var weakView=temporary;temporary=nil;XCTAssertNil(weakView);XCTAssertThrowsError(try m.displayedDocument())
        m.imageDisplayScale={100000};m.copyDisplayedImage();XCTAssertEqual(b.string(forType:.string),"keep me")
        withExtendedLifetime(v){}
    }
    func testDisplayedDocumentCanBeSavedAndDecodedWithoutChangingTheSource() throws {
        let (m,v,b)=try fixture();defer{b.releaseGlobally()}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("display-save-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let output=try m.displayedDocument(),save=CaptureManualImageSave(read:{nil},write:{_ in}),url=root.appendingPathComponent("display.png")
        try save.save(output,to:url,quality:0.9);let rep=try XCTUnwrap(NSBitmapImageRep(data:Data(contentsOf:url)))
        XCTAssertEqual(rep.pixelsWide,50);XCTAssertEqual(rep.pixelsHigh,25);XCTAssertEqual(m.document.size,CGSize(width:200,height:100));XCTAssertEqual(m.revision,0)
        withExtendedLifetime(v){}
    }
}
