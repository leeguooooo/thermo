import AppKit
import XCTest
@testable import CaptureCore

final class CaptureAnnotationBatchTests:XCTestCase {
    func testBatchEditsValidateEveryIndexAndKeepEachOperationInOneUndoStep() throws {
        let ctx=try XCTUnwrap(CGContext(data:nil,width:64,height:64,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        var doc=CaptureDocument(image:try XCTUnwrap(ctx.makeImage()))
        for x in [5,25,45] {doc.append(.init(tool:.rectangle,points:[CGPoint(x:x,y:5),CGPoint(x:x+10,y:15)]))}
        let moved=[0:doc.annotations[0].moved(dx:3,dy:4),2:doc.annotations[2].moved(dx:3,dy:4)]
        doc.replaceAnnotations(moved);XCTAssertEqual(doc.annotations[0].points[0].x,8);XCTAssertEqual(doc.annotations[2].points[0].x,48)
        doc.undo();XCTAssertEqual(doc.annotations[0].points[0].x,5);XCTAssertEqual(doc.annotations[2].points[0].x,45)
        doc.redo();XCTAssertEqual(doc.annotations[2].points[0].x,48)
        doc.replaceAnnotations([0:moved[0]!,99:moved[2]!]);doc.removeAnnotations(at:[0,99]);XCTAssertEqual(doc.annotations.count,3)
        doc.removeAnnotations(at:[0,2]);XCTAssertEqual(doc.annotations.count,1);XCTAssertEqual(doc.annotations[0].points[0].x,25)
        doc.undo();XCTAssertEqual(doc.annotations.count,3);XCTAssertEqual(doc.annotations[2].points[0].x,48)
    }
    func testGroupPreviewRendersReplacementsWithoutOriginalMarksAndDoesNotMutateDocument() throws {
        let ctx=try XCTUnwrap(CGContext(data:nil,width:64,height:64,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(NSColor.white.cgColor);ctx.fill(CGRect(x:0,y:0,width:64,height:64))
        var doc=CaptureDocument(image:try XCTUnwrap(ctx.makeImage()))
        for x in [5,25] {doc.append(.init(tool:.redact,points:[CGPoint(x:x,y:5),CGPoint(x:x+10,y:15)]))}
        let rep=NSBitmapImageRep(cgImage:try doc.rendered(replacements:Dictionary(uniqueKeysWithValues:doc.annotations.enumerated().map{($0.offset,$0.element.moved(dx:0,dy:30))})))
        XCTAssertGreaterThan(try XCTUnwrap(rep.colorAt(x:10,y:54)?.usingColorSpace(.deviceRGB)).redComponent,0.99)
        XCTAssertLessThan(try XCTUnwrap(rep.colorAt(x:30,y:24)?.usingColorSpace(.deviceRGB)).redComponent,0.01)
        XCTAssertEqual(doc.annotations[0].points[0].y,5);XCTAssertEqual(doc.annotations.count,2)
    }
}
