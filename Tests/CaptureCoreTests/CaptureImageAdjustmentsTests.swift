import AppKit
import XCTest
@testable import CaptureCore

final class CaptureImageAdjustmentsTests:XCTestCase {
    private func document(alpha:CGFloat=1) throws -> CaptureDocument {
        let c=try XCTUnwrap(CGContext(data:nil,width:80,height:60,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue));c.setFillColor(NSColor(deviceRed:0.8,green:0.2,blue:0.1,alpha:alpha).cgColor);c.fill(CGRect(x:0,y:0,width:80,height:60));return CaptureDocument(image:try XCTUnwrap(c.makeImage()))
    }
    private func pixel(_ doc:CaptureDocument,_ x:Int=0,_ y:Int=0) throws -> NSColor {try XCTUnwrap(NSBitmapImageRep(cgImage:doc.rendered()).colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB))}
    func testGrayscaleInversionBrightnessAndAlphaHaveExpectedPixels() throws {
        var doc=try document(alpha:0.6)
        try doc.applyImageAdjustments(.init(grayscale:true));let gray=try pixel(doc)
        XCTAssertEqual(gray.redComponent,0.32,accuracy:0.025);XCTAssertEqual(gray.redComponent,gray.greenComponent,accuracy:0.01);XCTAssertEqual(gray.blueComponent,gray.greenComponent,accuracy:0.01);XCTAssertEqual(gray.alphaComponent,0.6,accuracy:0.01)
        try doc.applyImageAdjustments(.init(inverted:true));let negative=try pixel(doc)
        XCTAssertEqual(negative.redComponent,0.2,accuracy:0.025);XCTAssertEqual(negative.greenComponent,0.8,accuracy:0.025);XCTAssertEqual(negative.blueComponent,0.9,accuracy:0.025)
        try doc.applyImageAdjustments(.init(brightness:2));let bright=try pixel(doc)
        XCTAssertEqual(bright.redComponent,1,accuracy:0.025);XCTAssertEqual(bright.greenComponent,0.4,accuracy:0.025);XCTAssertEqual(bright.blueComponent,0.2,accuracy:0.025)
    }
    func testAnnotationsRetainColorAndEraserRestoresTheAdjustedBase() throws {
        var doc=try document();try doc.applyImageAdjustments(.init(grayscale:true))
        doc.append(.init(tool:.redact,points:[CGPoint(x:10,y:10),CGPoint(x:70,y:50)]))
        doc.append(.init(tool:.eraserRect,points:[CGPoint(x:20,y:20),CGPoint(x:60,y:40)]))
        doc.append(.init(tool:.rectangle,points:[CGPoint(x:5,y:5),CGPoint(x:75,y:55)],color:.green,width:4))
        let restored=try pixel(doc,40,30),black=try pixel(doc,15,30),green=try pixel(doc,5,30)
        XCTAssertEqual(restored.redComponent,0.32,accuracy:0.025);XCTAssertEqual(restored.redComponent,restored.greenComponent,accuracy:0.01)
        XCTAssertLessThan(black.redComponent,0.01);XCTAssertGreaterThan(green.greenComponent,0.9);XCTAssertLessThan(green.redComponent,0.1)
    }
    func testResetUndoAndNoOpKeepOriginalPixelsAndHistory() throws {
        var doc=try document();let base=try doc.data();try doc.applyImageAdjustments(.init());XCTAssertFalse(doc.canUndo)
        try doc.applyImageAdjustments(.init(grayscale:true));XCTAssertEqual(try CaptureDocument(image:doc.image).data(),base)
        let gray=try doc.data();XCTAssertNotEqual(gray,base);try doc.applyImageAdjustments(.init());XCTAssertEqual(try doc.data(),base)
        doc.undo();XCTAssertEqual(try doc.data(),gray);doc.undo();XCTAssertEqual(try doc.data(),base);doc.redo();XCTAssertEqual(try doc.data(),gray)
        for bad in [Double.nan,.infinity,-0.1,2.1] {XCTAssertThrowsError(try doc.applyImageAdjustments(.init(brightness:bad)))}
        XCTAssertEqual(try doc.data(),gray)
    }
    func testGeometryFlattensCurrentAdjustmentAndUndoRestoresItsEditableParameters() throws {
        var doc=try document();try doc.applyImageAdjustments(.init(grayscale:true));let adjusted=try doc.data()
        try doc.crop(to:CGRect(x:10,y:10,width:40,height:20));XCTAssertTrue(doc.imageAdjustments.isDefault);let cropped=try pixel(doc);XCTAssertEqual(cropped.redComponent,cropped.greenComponent,accuracy:0.01)
        doc.undo();XCTAssertTrue(doc.imageAdjustments.grayscale);XCTAssertEqual(try doc.data(),adjusted)
        try doc.transform(rotateClockwise:true);XCTAssertTrue(doc.imageAdjustments.isDefault);XCTAssertEqual(doc.size,CGSize(width:60,height:80))
        doc.undo();XCTAssertEqual(try doc.data(),adjusted);XCTAssertTrue(doc.imageAdjustments.grayscale)
    }
    func testManifestKeepsParametersAndUnadjustedBaseAndFreshStoreRestoresSamePng() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("image-adjustments-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let store=CapturePinLibraryStore(root:root);var library=try store.load();let pin=CaptureSavedPin(groupID:library.currentGroupID);library.pins=[pin]
        var doc=try document();let original=try doc.data();try doc.applyImageAdjustments(.init(grayscale:true,inverted:true,brightness:1.2))
        let committed=try store.save(library,documents:[pin.id:doc]);XCTAssertEqual(committed.pins[0].imageAdjustments,doc.imageAdjustments)
        let png=root.appendingPathComponent("snapshots/"+pin.snapshotID.uuidString+"/image.png"),rep=try XCTUnwrap(NSBitmapImageRep(data:Data(contentsOf:png))),base=try XCTUnwrap(rep.colorAt(x:0,y:0)?.usingColorSpace(.deviceRGB))
        let originalRep=try XCTUnwrap(NSBitmapImageRep(data:original)),originalColor=try XCTUnwrap(originalRep.colorAt(x:0,y:0)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(base.redComponent,originalColor.redComponent,accuracy:0.001);XCTAssertEqual(base.greenComponent,originalColor.greenComponent,accuracy:0.001);XCTAssertGreaterThan(base.redComponent-base.greenComponent,0.4)
        let fresh=CapturePinLibraryStore(root:root),loaded=try fresh.load(),restored=try fresh.document(for:loaded.pins[0]);XCTAssertEqual(restored.imageAdjustments,doc.imageAdjustments);XCTAssertEqual(try restored.data(),try doc.data())
    }
    func testLegacyManifestUsesDefaultsAndMalformedAdjustmentIsRejected() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("legacy-adjustments-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let store=CapturePinLibraryStore(root:root);var library=try store.load();let pin=CaptureSavedPin(groupID:library.currentGroupID);library.pins=[pin]
        try store.save(library,documents:[pin.id:document()]);let fresh=CapturePinLibraryStore(root:root),loaded=try fresh.load();XCTAssertNil(loaded.pins[0].imageAdjustments);XCTAssertTrue(try fresh.document(for:loaded.pins[0]).imageAdjustments.isDefault)
        let url=root.appendingPathComponent("library.json");var raw=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any]);var pins=try XCTUnwrap(raw["pins"] as? [[String:Any]])
        pins[0]["imageAdjustments"]=["grayscale":true,"inverted":false,"brightness":3];raw["pins"]=pins;try JSONSerialization.data(withJSONObject:raw).write(to:url)
        XCTAssertThrowsError(try CapturePinLibraryStore(root:root).load())
    }
}
