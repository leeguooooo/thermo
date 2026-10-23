import AppKit
import XCTest
@testable import CaptureCore

final class CaptureAnnotationStylesTests:XCTestCase {
    private func image() throws -> CGImage {
        let ctx=try XCTUnwrap(CGContext(data:nil,width:300,height:200,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.clear(CGRect(x:0,y:0,width:300,height:200));return try XCTUnwrap(ctx.makeImage())
    }
    private func alpha(_ image:CGImage,_ x:Int,_ y:Int) -> CGFloat {NSBitmapImageRep(cgImage:image).colorAt(x:x,y:image.height-1-y)?.alphaComponent ?? 0}
    private func render(_ annotation:CaptureAnnotation) throws -> CGImage {try CaptureDocument(image:image(),annotations:[annotation]).rendered()}
    func testLegacyOptionsDecodeDefaultsAndNewOptionsRoundTripAndRejectInvalidValues() throws {
        let legacy=try JSONDecoder().decode(CaptureAnnotationOptions.self,from:Data(#"{"strength":18,"zoom":2,"opacity":0.6,"angle":-30,"ellipse":false}"#.utf8))
        XCTAssertEqual(legacy.arrowStart,.none);XCTAssertEqual(legacy.arrowEnd,.open);XCTAssertEqual(legacy.linePattern,.solid);XCTAssertNil(legacy.numberValue);XCTAssertFalse(legacy.numberLeader)
        var changed=legacy;changed.arrowStart = .circle;changed.arrowEnd = .diamond;changed.linePattern = .dotted;changed.numberFormat = .roman;changed.numberShape = .square;changed.numberFilled=false;changed.numberValue=49
        XCTAssertEqual(try JSONDecoder().decode(CaptureAnnotationOptions.self,from:JSONEncoder().encode(changed)),changed)
        changed.numberValue=4000;XCTAssertFalse(changed.valid);changed.numberValue=0;XCTAssertFalse(changed.valid)
        XCTAssertThrowsError(try JSONDecoder().decode(CaptureAnnotationOptions.self,from:Data(#"{"arrowEnd":"unknown"}"#.utf8)))
    }
    func testSequenceFormatsCoverBoundariesAndBadgeFitsWideText() {
        XCTAssertEqual(CaptureNumberFormat.alphabetic.label(26),"Z");XCTAssertEqual(CaptureNumberFormat.alphabetic.label(27),"AA");XCTAssertEqual(CaptureNumberFormat.alphabetic.label(703),"AAA")
        XCTAssertEqual(CaptureNumberFormat.roman.label(49),"XLIX");XCTAssertEqual(CaptureNumberFormat.roman.label(3999),"MMMCMXCIX");XCTAssertEqual(CaptureNumberFormat.roman.label(4000),"")
        var badge=CaptureAnnotation(tool:.number,points:[CGPoint(x:150,y:100)],text:"legacy")
        XCTAssertEqual(badge.numberLabel,"legacy");badge.options.numberValue=3999;badge.options.numberFormat = .roman
        XCTAssertGreaterThan(badge.bounds.width,48);XCTAssertEqual(badge.numberLabel,"MMMCMXCIX")
    }
    func testLinePatternsHaveRealGapsAndRetainPolylineBends() throws {
        var line=CaptureAnnotation(tool:.line,points:[CGPoint(x:20,y:100),CGPoint(x:280,y:100)],color:.red,width:2)
        let solid=try render(line)
        for pattern in [CaptureLinePattern.dashed,.dotted] {
            line.options.linePattern=pattern;let result=try render(line)
            let gaps=(30..<270).filter{alpha(result,$0,100)<0.1}
            XCTAssertGreaterThan(gaps.count,30);XCTAssertTrue(gaps.allSatisfy{alpha(solid,$0,100)>0.9})
        }
        line.points=[CGPoint(x:20,y:20),CGPoint(x:150,y:170),CGPoint(x:280,y:20)];line.options.linePattern = .solid
        let bent=try render(line);XCTAssertGreaterThan(alpha(bent,150,170),0.5);XCTAssertLessThan(alpha(bent,150,20),0.1)
    }
    func testEachArrowHeadRendersAndMarkerAreaIsSelectable() throws {
        var arrow=CaptureAnnotation(tool:.arrow,points:[CGPoint(x:50,y:100),CGPoint(x:250,y:100)],color:.red,width:4)
        var hashes=Set<Data>()
        for style in CaptureArrowHead.allCases {
            arrow.options.arrowStart=style;arrow.options.arrowEnd=style
            hashes.insert(try CaptureDocument(image:image(),annotations:[arrow]).data())
            let result=try render(arrow);XCTAssertGreaterThan(alpha(result,150,100),0.9)
        }
        XCTAssertEqual(hashes.count,5)
        arrow.options.arrowEnd = .diamond
        let doc=CaptureDocument(image:try image(),annotations:[arrow])
        XCTAssertEqual(doc.hitTest(CGPoint(x:235,y:105),tolerance:0),0)
        XCTAssertNil(doc.hitTest(CGPoint(x:150,y:130),tolerance:0))
        XCTAssertTrue(arrow.bounds.contains(CGPoint(x:219,y:100)))
    }
    func testNumberFillShapeAndDraggedLeaderAffectPixels() throws {
        var number=CaptureAnnotation(tool:.number,points:[CGPoint(x:80,y:100),CGPoint(x:240,y:100)],color:.red,width:3,text:"1")
        let legacy=try render(number);XCTAssertLessThan(alpha(legacy,180,100),0.1)
        number.options.numberLeader=true;number.options.numberValue=27;number.options.numberFormat = .alphabetic
        let filled=try render(number);XCTAssertGreaterThan(alpha(filled,80,90),0.9);XCTAssertGreaterThan(alpha(filled,180,100),0.9)
        number.options.numberFilled=false
        let outlined=try render(number);XCTAssertLessThan(alpha(outlined,80,90),0.1)
        number.options.numberShape = .square
        let square=try render(number);XCTAssertGreaterThan(alpha(square,62,82),0.5);XCTAssertLessThan(alpha(outlined,62,82),0.1)
        XCTAssertTrue(number.bounds.contains(CGPoint(x:240,y:100)))
    }
    func testSnapshotRestoresNewStyleAndExactlySameRenderedImage() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("annotation-style-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let store=CapturePinLibraryStore(root:root);var library=try store.load();let pin=CaptureSavedPin(groupID:library.currentGroupID);library.pins=[pin]
        var arrow=CaptureAnnotation(tool:.arrow,points:[CGPoint(x:40,y:140),CGPoint(x:240,y:140)])
        arrow.options.arrowStart = .circle;arrow.options.arrowEnd = .filled;arrow.options.linePattern = .dashed
        var badge=CaptureAnnotation(tool:.number,points:[CGPoint(x:80,y:60),CGPoint(x:200,y:60)])
        badge.options.numberLeader=true;badge.options.numberValue=28;badge.options.numberFormat = .roman;badge.options.numberFilled=false;badge.options.numberShape = .square
        let doc=CaptureDocument(image:try image(),annotations:[arrow,badge]);try store.save(library,documents:[pin.id:doc])
        let fresh=CapturePinLibraryStore(root:root),loaded=try fresh.load(),restored=try fresh.document(for:loaded.pins[0])
        XCTAssertEqual(restored.annotations[0].options,arrow.options);XCTAssertEqual(restored.annotations[1].options,badge.options)
        XCTAssertEqual(try doc.data(),try restored.data())
    }
    func testAngleSnapStaysAtFortyFiveDegreesWithinImage() {
        let p=CaptureAnnotation.snappedEndpoint(from:CGPoint(x:90,y:90),to:CGPoint(x:130,y:120),inside:CGSize(width:100,height:100))
        XCTAssertEqual(p.x,100,accuracy:0.001);XCTAssertEqual(p.y,100,accuracy:0.001)
        let horizontal=CaptureAnnotation.snappedEndpoint(from:CGPoint(x:20,y:20),to:CGPoint(x:80,y:25),inside:CGSize(width:100,height:100))
        XCTAssertEqual(horizontal.y,20,accuracy:0.001)
    }
}
