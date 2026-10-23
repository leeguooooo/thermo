import AppKit
import XCTest
@testable import CaptureCore

final class CaptureImageTransformTests:XCTestCase {
    private func document() throws -> CaptureDocument {
        let c=try XCTUnwrap(CGContext(data:nil,width:6,height:4,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        for y in 0..<4 {for x in 0..<6 {
            c.setFillColor(NSColor(deviceRed:Double(x+1)/7,green:Double(y+1)/5,blue:Double(x+y+1)/11,alpha:y%2==0 ? 0.5 : 1).cgColor);c.fill(CGRect(x:x,y:y,width:1,height:1))
        }}
        return CaptureDocument(image:try XCTUnwrap(c.makeImage()))
    }
    private func pixel(_ image:CGImage,_ x:Int,_ y:Int) throws -> NSColor {
        try XCTUnwrap(NSBitmapImageRep(cgImage:image).colorAt(x:x,y:image.height-1-y)?.usingColorSpace(.deviceRGB))
    }
    func testAllFourDirectionsMapEveryPixelAndPreserveAlpha() throws {
        let base=try document(),input=try base.rendered()
        for operation in CaptureImageTransform.allCases {
            var doc=base;try doc.transform(operation);let output=try doc.rendered()
            let rotated=operation == .rotateClockwise || operation == .rotateCounterclockwise
            XCTAssertEqual(output.width,rotated ? 4 : 6);XCTAssertEqual(output.height,rotated ? 6 : 4)
            for y in 0..<4 {for x in 0..<6 {
                let target:(Int,Int)
                switch operation {case .rotateClockwise:target=(y,5-x);case .rotateCounterclockwise:target=(3-y,x);case .flipHorizontal:target=(5-x,y);case .flipVertical:target=(x,3-y)}
                let before=try pixel(input,x,y),after=try pixel(output,target.0,target.1)
                XCTAssertEqual(before.redComponent,after.redComponent,accuracy:0.01);XCTAssertEqual(before.greenComponent,after.greenComponent,accuracy:0.01);XCTAssertEqual(before.blueComponent,after.blueComponent,accuracy:0.01);XCTAssertEqual(before.alphaComponent,after.alphaComponent,accuracy:0.01)
            }}
        }
    }
    func testOppositeRotationsAndDoubleMirrorsRestoreIdenticalPixels() throws {
        let base=try document(),expected=try base.data()
        for operations in [[CaptureImageTransform.rotateCounterclockwise,.rotateClockwise],[.rotateClockwise,.rotateCounterclockwise],[.flipVertical,.flipVertical],[.flipHorizontal,.flipHorizontal]] {
            var doc=base;for operation in operations {try doc.transform(operation)};XCTAssertEqual(try doc.data(),expected)
        }
    }
    func testFlatteningIsOneUndoAndRestoresEditableAnnotationsAndColorParameters() throws {
        var doc=try document();doc.append(.init(tool:.redact,points:[.zero,CGPoint(x:2,y:2)]));try doc.applyImageAdjustments(.init(inverted:true,brightness:0.9))
        let expected=try doc.data()
        try doc.transform(.rotateCounterclockwise);let rotated=try doc.data();XCTAssertEqual(doc.size,CGSize(width:4,height:6));XCTAssertTrue(doc.annotations.isEmpty);XCTAssertTrue(doc.imageAdjustments.isDefault)
        doc.undo();XCTAssertEqual(try doc.data(),expected);XCTAssertEqual(doc.annotations.count,1);XCTAssertEqual(doc.imageAdjustments,.init(inverted:true,brightness:0.9))
        doc.redo();XCTAssertEqual(try doc.data(),rotated)
    }
    func testLegacyCombinedTransformOrderAndSingleUndoRemainCompatible() throws {
        let base=try document();var combined=base,separate=base
        try combined.transform(rotateClockwise:true,flipHorizontal:true)
        try separate.transform(.flipHorizontal);try separate.transform(.rotateClockwise)
        XCTAssertEqual(try combined.data(),try separate.data())
        combined.undo();XCTAssertEqual(try combined.data(),try base.data());XCTAssertFalse(combined.canUndo)
    }
}
