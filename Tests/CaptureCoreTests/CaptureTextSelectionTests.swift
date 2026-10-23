import AppKit
import XCTest
@testable import CaptureCore

final class CaptureTextSelectionTests:XCTestCase {
    private func segments(_ text:String) -> [CaptureTextSegment] {
        var output:[CaptureTextSegment]=[]
        text.enumerateSubstrings(in:text.startIndex..<text.endIndex,options:.byComposedCharacterSequences) {value,range,_,_ in
            if value?.allSatisfy(\.isWhitespace) != true {output.append(.init(range:NSRange(range,in:text),bounds:CGRect(x:0.1,y:0.1,width:0.1,height:0.1)))}
        };return output
    }
    func testUnicodeWhitespaceAndDisjointSelectionsPreserveSourceText() {
        let source="Hello 世界\nnext 😀 e\u{301}",items=segments(source)
        XCTAssertEqual(CaptureTextSelection.text(in:source,segments:items,selected:Set(items.indices)),source)
        XCTAssertEqual(CaptureTextSelection.text(in:source,segments:items,selected:[0,4]),"H o")
        XCTAssertEqual(CaptureTextSelection.text(in:source,segments:items,selected:[5,6]),"世界")
        XCTAssertEqual(CaptureTextSelection.text(in:source,segments:items,selected:[0,7]),"H\nn")
        XCTAssertEqual(CaptureTextSelection.text(in:source,segments:items,selected:[11,12]),"😀 e\u{301}")
    }
    func testInvalidIndicesRangesAndOverlapsNeverDuplicateOrCrash() {
        let source="ABC",box=CGRect(x:0,y:0,width:1,height:1)
        let items=[CaptureTextSegment(range:NSRange(location:0,length:2),bounds:box),.init(range:NSRange(location:1,length:2),bounds:box),.init(range:NSRange(location:Int.max,length:Int.max),bounds:box),.init(range:NSRange(location:0,length:0),bounds:box)]
        XCTAssertEqual(CaptureTextSelection.text(in:source,segments:items,selected:[-1,0,1,2,3,99]),"ABC")
        XCTAssertEqual(CaptureTextSelection.text(in:source,segments:items,selected:[2,3,99]),"")
    }
    @MainActor func testActualBilingualVisionGeometrySelectsWordAndMatchesImageCoordinates() throws {
        _=NSApplication.shared
        let ctx=try XCTUnwrap(CGContext(data:nil,width:1200,height:360,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(NSColor.white.cgColor);ctx.fill(CGRect(x:0,y:0,width:1200,height:360))
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:ctx,flipped:false)
        let attributes:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:42),.foregroundColor:NSColor.black]
        ("THERMO 31337" as NSString).draw(at:CGPoint(x:60,y:230),withAttributes:attributes)
        ("截图测试 你好世界" as NSString).draw(at:CGPoint(x:60,y:100),withAttributes:attributes)
        NSGraphicsContext.restoreGraphicsState()
        let result=try CaptureRecognition.recognize(XCTUnwrap(ctx.makeImage()),includeGeometry:true)
        XCTAssertTrue(result.text.contains("THERMO"));XCTAssertTrue(result.text.contains("31337"));XCTAssertTrue(result.text.filter{!$0.isWhitespace}.contains("截图测试"))
        let word=NSRange(try XCTUnwrap(result.text.range(of:"THERMO")),in:result.text)
        let indices=Set(result.segments.indices.filter {let range=result.segments[$0].range;return range.location>=word.location && NSMaxRange(range)<=NSMaxRange(word)})
        XCTAssertFalse(indices.isEmpty)
        XCTAssertEqual(CaptureTextSelection.text(in:result.text,segments:result.segments,selected:indices),"THERMO")
        for index in indices {XCTAssertGreaterThan(result.segments[index].bounds.midY,0.5)}
        for item in result.segments {
            XCTAssertNotNil(Range(item.range,in:result.text));XCTAssertGreaterThan(item.bounds.width,0);XCTAssertGreaterThanOrEqual(item.bounds.minX,-0.001);XCTAssertLessThanOrEqual(item.bounds.maxY,1.001)
        }
    }
}
