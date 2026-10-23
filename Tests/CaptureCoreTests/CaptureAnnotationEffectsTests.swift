import AppKit
import XCTest
@testable import CaptureCore

final class CaptureAnnotationEffectsTests:XCTestCase {
    func image(checker:Bool = false,transparent:Bool = false) throws -> CGImage {
        let ctx=try XCTUnwrap(CGContext(data:nil,width:64,height:64,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        if transparent { ctx.clear(CGRect(x:0,y:0,width:64,height:64)) }
        else { for y in 0..<64 { for x in 0..<64 {
            ctx.setFillColor(checker ? ((x+y)%2 == 0 ? NSColor.red : NSColor.blue).cgColor : NSColor(deviceWhite:Double(x)/63,alpha:1).cgColor)
            ctx.fill(CGRect(x:x,y:y,width:1,height:1))
        } } }
        return try XCTUnwrap(ctx.makeImage())
    }
    func color(_ image:CGImage,x:Int,y:Int) throws -> NSColor { try XCTUnwrap(NSBitmapImageRep(cgImage:image).colorAt(x:x,y:63-y)?.usingColorSpace(.deviceRGB)) }
    func annotation(_ tool:CaptureTool,rect:CGRect = CGRect(x:16,y:16,width:32,height:32)) -> CaptureAnnotation {
        .init(tool:tool,points:[rect.origin,CGPoint(x:rect.maxX,y:rect.maxY)],width:1)
    }
    func testMosaicUsesBlockAverageAndLeavesOtherPixelsUntouched() throws {
        let source=try image(checker:true);var doc=CaptureDocument(image:source),item=annotation(.mosaic)
        item.options.strength=8;doc.append(item)
        let result=try doc.rendered(),sample=try color(result,x:20,y:20)
        XCTAssertEqual(sample.redComponent,0.5,accuracy:0.02);XCTAssertEqual(sample.blueComponent,0.5,accuracy:0.02)
        for x in 16..<24 { for y in 16..<24 { XCTAssertEqual(try color(result,x:x,y:y).redComponent,sample.redComponent,accuracy:0.001) } }
        XCTAssertEqual(try color(result,x:4,y:4),try color(source,x:4,y:4))
        doc.undo();XCTAssertEqual(try doc.data(),try CaptureDocument(image:source).data());doc.redo();XCTAssertEqual(try doc.data(),try CaptureDocument(image:result).data())
    }
    func testBlurSmoothsDetailsOnlyInsideSelection() throws {
        let source=try image(checker:true);var doc=CaptureDocument(image:source),item=annotation(.blur);item.options.strength=4;doc.append(item)
        let result=try doc.rendered()
        XCTAssertLessThan(abs(try color(result,x:30,y:30).redComponent-color(result,x:31,y:30).redComponent),0.05)
        XCTAssertEqual(try color(result,x:4,y:4),try color(source,x:4,y:4))
    }
    func testRectangleAndBrushErasersRestoreBaseInsteadOfClearingIt() throws {
        let source=try image();var rectangle=CaptureDocument(image:source)
        rectangle.append(annotation(.redact,rect:CGRect(x:8,y:8,width:48,height:48)));rectangle.append(annotation(.eraserRect))
        let restored=try rectangle.rendered()
        XCTAssertEqual(try color(restored,x:30,y:30),try color(source,x:30,y:30));XCTAssertEqual(try color(restored,x:30,y:30).alphaComponent,1)
        XCTAssertLessThan(try color(restored,x:10,y:10).redComponent,0.01)
        var brush=CaptureDocument(image:source);brush.append(annotation(.redact))
        brush.append(.init(tool:.eraser,points:[CGPoint(x:20,y:20),CGPoint(x:44,y:44)],width:2))
        XCTAssertEqual(try color(brush.rendered(),x:30,y:30),try color(source,x:30,y:30))
        XCTAssertLessThan(try color(brush.rendered(),x:20,y:40).redComponent,0.01)
        let transparent=try image(transparent:true);var clear=CaptureDocument(image:transparent)
        clear.append(annotation(.redact));clear.append(annotation(.eraserRect))
        XCTAssertEqual(try color(clear.rendered(),x:30,y:30).alphaComponent,0)
    }
    func testSpotlightKeepsHoleAndDimsOutsideIncludingEllipseCorners() throws {
        let source=try image();var doc=CaptureDocument(image:source),item=annotation(.spotlight)
        item.options.opacity=0.5;doc.append(item)
        XCTAssertEqual(try color(doc.rendered(),x:32,y:32).redComponent,try color(source,x:32,y:32).redComponent,accuracy:0.005)
        XCTAssertEqual(try color(doc.rendered(),x:60,y:20).redComponent,try color(source,x:60,y:20).redComponent/2,accuracy:0.01)
        item.options.ellipse=true;doc.replaceAnnotation(at:0,with:item)
        XCTAssertLessThan(try color(doc.rendered(),x:17,y:17).redComponent,try color(source,x:17,y:17).redComponent*0.7)
    }
    func testMagnifierSamplesSmallerSourceRegionAndWatermarkRenders() throws {
        let source=try image();var doc=CaptureDocument(image:source),item=annotation(.magnifier)
        item.options.zoom=2;doc.append(item)
        XCTAssertEqual(try color(doc.rendered(),x:20,y:32).redComponent,26.0/63,accuracy:0.03)
        XCTAssertEqual(try color(doc.rendered(),x:4,y:4),try color(source,x:4,y:4))
        doc.clearAnnotations();var mark=annotation(.watermark,rect:CGRect(x:0,y:0,width:64,height:64));mark.text="QA";mark.options.angle=0;doc.append(mark)
        XCTAssertNotEqual(try doc.data(),try CaptureDocument(image:source).data())
    }
    func testSelectionReplacementMovementAndDeleteAreUndoable() throws {
        var doc=CaptureDocument(image:try image());let first=annotation(.rectangle),second=annotation(.ellipse,rect:CGRect(x:24,y:24,width:16,height:16))
        doc.append(first);doc.append(second);XCTAssertEqual(doc.hitTest(CGPoint(x:30,y:30)),1)
        doc.replaceAnnotation(at:1,with:second.moved(dx:10,dy:0));XCTAssertEqual(doc.annotations[1].points[0].x,34)
        doc.undo();XCTAssertEqual(doc.annotations[1].points[0].x,24)
        doc.removeAnnotation(at:1);XCTAssertEqual(doc.annotations.count,1);doc.undo();XCTAssertEqual(doc.annotations.count,2)
        let resized=first.resized(to:CGRect(x:8,y:8,width:48,height:48));XCTAssertGreaterThan(resized.bounds.width,first.bounds.width)
        doc.clearAnnotations();XCTAssertTrue(doc.annotations.isEmpty);doc.undo();XCTAssertEqual(doc.annotations.count,2)
    }
    func testInvalidEffectParametersFailBeforeExportingOriginalPixels() throws {
        var doc=CaptureDocument(image:try image()),item=annotation(.mosaic);item.options.strength = .nan;doc.append(item)
        XCTAssertThrowsError(try doc.data())
    }
}

extension CaptureAnnotationEffectsTests {
    func testImageEffectsAndEraserRespectTransformedCropCoordinates() throws {
        let source=try image(checker:true),ctx=try XCTUnwrap(CGContext(data:nil,width:32,height:64,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.translateBy(x:-32,y:0);ctx.draw(source,in:CGRect(x:0,y:0,width:64,height:64))
        let base=try XCTUnwrap(ctx.makeImage())
        var mark=annotation(.mosaic,rect:CGRect(x:40,y:16,width:16,height:32));mark.options.strength=8
        try CaptureDocument.draw(mark,in:ctx,base:base)
        let modified=try XCTUnwrap(ctx.makeImage())
        let pixel=try XCTUnwrap(NSBitmapImageRep(cgImage:modified).colorAt(x:12,y:32)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(pixel.redComponent,0.5,accuracy:0.02)
        try CaptureDocument.draw(annotation(.eraserRect,rect:CGRect(x:40,y:16,width:16,height:32)),in:ctx,base:base)
        let restored=try XCTUnwrap(ctx.makeImage())
        XCTAssertEqual(try CaptureDocument(image:restored).data(),try CaptureDocument(image:base).data())
    }
    func testEffectOptionsRoundTripAndOldVectorDataRemainCompatible() throws {
        var item=annotation(.blur);item.options.strength=31;item.options.ellipse=true
        let record=CaptureVectorAnnotation(item,start:0.5,end:2)
        let roundtrip=try JSONDecoder().decode(CaptureVectorAnnotation.self,from:JSONEncoder().encode(record))
        XCTAssertEqual(roundtrip.annotation?.options.strength,31)
        var legacy=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(record)) as? [String:Any]);legacy.removeValue(forKey:"options")
        let old=try JSONDecoder().decode(CaptureVectorAnnotation.self,from:JSONSerialization.data(withJSONObject:legacy))
        XCTAssertEqual(old.annotation?.options.strength,12)
    }
}
