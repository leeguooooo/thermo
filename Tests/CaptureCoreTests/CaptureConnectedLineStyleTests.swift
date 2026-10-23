import AppKit
import XCTest
@testable import CaptureCore

final class CaptureConnectedLineStyleTests:XCTestCase {
    private func image() throws -> CGImage {
        let c=try XCTUnwrap(CGContext(data:nil,width:300,height:200,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue));return try XCTUnwrap(c.makeImage())
    }
    func testLegacyLinesKeepNoMarkersAndRoundJoinsAndCaps() throws {
        let options=try JSONDecoder().decode(CaptureAnnotationOptions.self,from:Data(#"{"strength":12,"zoom":2,"opacity":0.6,"angle":-30,"ellipse":false}"#.utf8))
        XCTAssertEqual(options.lineStart,.none);XCTAssertEqual(options.lineEnd,.none);XCTAssertEqual(options.lineJoin,.round);XCTAssertEqual(options.lineCap,.round)
    }
    func testCapsJoinsAndEndMarkersChangeActualPixelsAndAreSelectable() throws {
        var line=CaptureAnnotation(tool:.line,points:[CGPoint(x:40,y:40),CGPoint(x:140,y:160),CGPoint(x:260,y:40)],width:12)
        let round=try CaptureDocument(image:image(),annotations:[line]).data()
        line.options.lineJoin = .miter;let sharp=try CaptureDocument(image:image(),annotations:[line]).data();XCTAssertNotEqual(round,sharp)
        line.options.lineCap = .square;let square=try CaptureDocument(image:image(),annotations:[line]).data();XCTAssertNotEqual(square,sharp)
        line.points=[CGPoint(x:40,y:100),CGPoint(x:260,y:100)];line.width=4;line.options.lineEnd = .diamond
        let doc=CaptureDocument(image:try image(),annotations:[line]);XCTAssertEqual(doc.hitTest(CGPoint(x:245,y:105),tolerance:0),0);XCTAssertTrue(line.bounds.contains(CGPoint(x:230,y:105)))
    }
    func testFreshSnapshotRestoresAllVerticesAndLineStylesWithSamePNG() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("connected-line-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let store=CapturePinLibraryStore(root:root);var library=try store.load();let pin=CaptureSavedPin(groupID:library.currentGroupID);library.pins=[pin]
        var line=CaptureAnnotation(tool:.line,points:[CGPoint(x:20,y:20),CGPoint(x:100,y:150),CGPoint(x:200,y:50),CGPoint(x:280,y:150)])
        line.options.lineStart = .circle;line.options.lineEnd = .filled;line.options.lineJoin = .miter;line.options.lineCap = .square;line.options.linePattern = .dashed
        let doc=CaptureDocument(image:try image(),annotations:[line]);try store.save(library,documents:[pin.id:doc])
        let fresh=CapturePinLibraryStore(root:root),loaded=try fresh.load(),restored=try fresh.document(for:loaded.pins[0])
        XCTAssertEqual(restored.annotations[0].points,line.points);XCTAssertEqual(restored.annotations[0].options,line.options);XCTAssertEqual(try restored.data(),try doc.data())
    }
    func testClosedPolylineStillRendersItsStartMarker() throws {
        var line=CaptureAnnotation(tool:.line,points:[CGPoint(x:40,y:40),CGPoint(x:240,y:40),CGPoint(x:240,y:160),CGPoint(x:40,y:40)],width:3)
        let plain=try CaptureDocument(image:image(),annotations:[line]).data()
        line.options.lineStart = .circle
        XCTAssertNotEqual(try CaptureDocument(image:image(),annotations:[line]).data(),plain)
    }
}
