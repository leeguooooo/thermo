import AppKit
import XCTest
@testable import CaptureCore

final class CaptureArrowCommentTests:XCTestCase {
    private func image() throws -> CGImage {
        let ctx=try XCTUnwrap(CGContext(data:nil,width:400,height:300,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue));return try XCTUnwrap(ctx.makeImage())
    }
    func testCommentRendersAndBoundsAndHitTestFollowCommentAwayFromShaft() throws {
        var arrow=CaptureAnnotation(tool:.arrow,points:[CGPoint(x:50,y:60),CGPoint(x:350,y:60)],color:.red,width:2)
        let before=try CaptureDocument(image:image(),annotations:[arrow]).data()
        arrow.options.arrowComment="Check this button\n检查按钮"
        let rect=try XCTUnwrap(arrow.arrowCommentRect)
        XCTAssertGreaterThan(rect.minY,60);XCTAssertTrue(arrow.bounds.contains(rect))
        let doc=CaptureDocument(image:try image(),annotations:[arrow]);XCTAssertNotEqual(try doc.data(),before)
        XCTAssertEqual(doc.hitTest(CGPoint(x:rect.midX,y:rect.midY),tolerance:0),0)
        let moved=arrow.moved(dx:20,dy:15);XCTAssertEqual(moved.arrowCommentRect?.origin.x,(rect.origin.x+20));XCTAssertEqual(moved.arrowCommentRect?.origin.y,(rect.origin.y+15))
        XCTAssertEqual(moved.options.arrowComment,arrow.options.arrowComment)
    }
    func testLegacyTextIsNotDrawnAsCommentAndOversizedCommentIsRejected() throws {
        var arrow=CaptureAnnotation(tool:.arrow,points:[CGPoint(x:50,y:60),CGPoint(x:350,y:60)],text:"Unrelated legacy text")
        XCTAssertNil(arrow.arrowCommentRect)
        let legacy=try JSONDecoder().decode(CaptureAnnotationOptions.self,from:Data(#"{"arrowEnd":"open"}"#.utf8));XCTAssertEqual(legacy.arrowComment,"")
        arrow.options.arrowComment=String(repeating:"x",count:2001);XCTAssertFalse(arrow.options.valid)
        XCTAssertThrowsError(try CaptureDocument(image:image(),annotations:[arrow]).rendered())
    }
    func testCommentSnapshotReopensWithSamePixelsAndEditableText() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("arrow-comment-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let store=CapturePinLibraryStore(root:root);var library=try store.load();let pin=CaptureSavedPin(groupID:library.currentGroupID);library.pins=[pin]
        var arrow=CaptureAnnotation(tool:.arrow,points:[CGPoint(x:50,y:60),CGPoint(x:350,y:200)]);arrow.options.arrowComment="Step 1 — click here";arrow.options.linePattern = .dashed
        let doc=CaptureDocument(image:try image(),annotations:[arrow]);try store.save(library,documents:[pin.id:doc])
        let fresh=CapturePinLibraryStore(root:root),loaded=try fresh.load(),restored=try fresh.document(for:loaded.pins[0])
        XCTAssertEqual(restored.annotations[0].options.arrowComment,arrow.options.arrowComment);XCTAssertEqual(try restored.data(),try doc.data())
    }
}
