import AppKit
import XCTest
@testable import CaptureCore

final class CaptureImageExportTests:XCTestCase {
    private func document() throws -> CaptureDocument {
        let c=try XCTUnwrap(CGContext(data:nil,width:80,height:60,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        c.setFillColor(NSColor.red.cgColor);c.fill(CGRect(x:0,y:0,width:80,height:60));return CaptureDocument(image:try XCTUnwrap(c.makeImage()))
    }
    func testDisplaySizeOpacityAndConfirmedAnnotationsAreFlattenedWithoutMutatingDocument() throws {
        var doc=try document();doc.append(.init(tool:.redact,points:[CGPoint(x:20,y:20),CGPoint(x:60,y:40)]))
        let before=try doc.data(),exported=try CaptureImageExport.displayed(doc,scale:0.5,opacity:0.4)
        XCTAssertEqual(exported.size,CGSize(width:40,height:30));XCTAssertTrue(exported.annotations.isEmpty)
        let rep=NSBitmapImageRep(cgImage:exported.image),corner=try XCTUnwrap(rep.colorAt(x:0,y:0)),center=try XCTUnwrap(rep.colorAt(x:20,y:15))
        XCTAssertEqual(corner.alphaComponent,0.4,accuracy:0.01);XCTAssertGreaterThan(corner.redComponent,0.99);XCTAssertLessThan(center.redComponent,0.02);XCTAssertEqual(center.alphaComponent,0.4,accuracy:0.01)
        XCTAssertEqual(try doc.data(),before);XCTAssertEqual(doc.annotations.count,1);XCTAssertTrue(doc.canUndo)
    }
    func testCropAndRotationUseTheCurrentEditedPixelDimensions() throws {
        var doc=try document();try doc.crop(to:CGRect(x:10,y:10,width:40,height:30));try doc.transform(rotateClockwise:true)
        let output=try CaptureImageExport.displayed(doc,scale:0.75,opacity:1)
        XCTAssertEqual(doc.size,CGSize(width:30,height:40));XCTAssertEqual(output.size,CGSize(width:23,height:30))
        doc.undo();XCTAssertEqual(doc.size,CGSize(width:40,height:30));doc.undo();XCTAssertEqual(doc.size,CGSize(width:80,height:60))
    }
    func testRejectsNonFiniteAndOversizedGeometryBeforeAllocation() throws {
        let doc=try document()
        for scale in [CGFloat.nan,.infinity,0,-1] {XCTAssertThrowsError(try CaptureImageExport.displayed(doc,scale:scale,opacity:1))}
        for opacity in [Double.nan,.infinity,-0.1,1.1] {XCTAssertThrowsError(try CaptureImageExport.displayed(doc,scale:1,opacity:opacity))}
        XCTAssertThrowsError(try CaptureImageExport.displayed(doc,scale:100000,opacity:1))
        let tiny=try CaptureImageExport.displayed(doc,scale:0.00001,opacity:0);XCTAssertEqual(tiny.size,CGSize(width:1,height:1));XCTAssertEqual(NSBitmapImageRep(cgImage:tiny.image).colorAt(x:0,y:0)?.alphaComponent,0)
    }
    func testDisplayedExportsUseTheExistingPngJpegAndTiffEncoders() throws {
        let output=try CaptureImageExport.displayed(document(),scale:0.5,opacity:0.25)
        for format in CaptureSaveFormat.allCases {
            let bytes=try CaptureImageSave.encode(output,format:format,quality:0.95),rep=try XCTUnwrap(NSBitmapImageRep(data:bytes))
            XCTAssertEqual(rep.pixelsWide,40);XCTAssertEqual(rep.pixelsHigh,30)
            let color=try XCTUnwrap(rep.colorAt(x:0,y:0)?.usingColorSpace(.deviceRGB))
            if format == .jpeg {XCTAssertGreaterThan(color.redComponent,0.95);XCTAssertEqual(color.greenComponent,0.75,accuracy:0.08);XCTAssertEqual(color.alphaComponent,1,accuracy:0.01)}
            else {XCTAssertEqual(color.alphaComponent,0.25,accuracy:0.01)}
        }
    }
}
