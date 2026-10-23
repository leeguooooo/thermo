import AppKit
import XCTest
@testable import CaptureCore

final class CaptureScrollStitcherTests:XCTestCase {
    private func noise(width:Int=80,height:Int=600,seed:UInt64=179) -> CGImage {
        var state=seed,bytes=[UInt8](repeating:255,count:width*height*4)
        for i in stride(from:0,to:bytes.count,by:4) {
            state=state &* 6364136223846793005 &+ 1
            for c in 0..<3 {bytes[i+c]=UInt8(truncatingIfNeeded:state >> (32+c*8))}
        }
        return image(bytes,width:width,height:height)
    }
    private func image(_ bytes:[UInt8],width:Int,height:Int) -> CGImage {
        CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:.init(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:CGDataProvider(data:Data(bytes) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
    }
    private func compose(_ body:CGImage,header:CGImage?,footer:CGImage?) throws -> CGImage {
        let leading=header?.height ?? 0,trailing=footer?.height ?? 0,height=body.height+leading+trailing
        let ctx=try CaptureStitcher.context(width:body.width,height:height)
        if let header {ctx.draw(header,in:CGRect(x:0,y:height-leading,width:body.width,height:leading))}
        ctx.draw(body,in:CGRect(x:0,y:trailing,width:body.width,height:body.height))
        if let footer {ctx.draw(footer,in:CGRect(x:0,y:0,width:body.width,height:trailing))}
        return try XCTUnwrap(ctx.makeImage())
    }
    private func viewport(_ source:CGImage,_ start:Int,header:CGImage?,footer:CGImage?) throws -> CGImage {
        try compose(XCTUnwrap(source.cropping(to:CGRect(x:0,y:start,width:source.width,height:128))),header:header,footer:footer)
    }
    private func equal(_ a:CGImage,_ b:CGImage,file:StaticString=#filePath,line:UInt=#line) throws {
        XCTAssertEqual(a.width,b.width,file:file,line:line);XCTAssertEqual(a.height,b.height,file:file,line:line)
        XCTAssertTrue(try CaptureStitcher.pixels(a).elementsEqual(CaptureStitcher.pixels(b)),"Stitched pixels changed",file:file,line:line)
    }
    func testAutomaticHeaderAndFooterAppearOnceWithEveryDocumentPixelPreserved() throws {
        let source=noise(),header=noise(height:12,seed:7),footer=noise(height:10,seed:9)
        var session=CaptureScrollStitcher()
        _=try session.append(viewport(source,0,header:header,footer:footer))
        _=try session.append(viewport(source,80,header:header,footer:footer))
        let result=try session.append(viewport(source,160,header:header,footer:footer))
        XCTAssertEqual(result.fixedLeading,12);XCTAssertEqual(result.fixedTrailing,10);XCTAssertEqual(result.viewportOffset,160)
        let body=try XCTUnwrap(source.cropping(to:CGRect(x:0,y:0,width:80,height:288)))
        try equal(result.image,compose(body,header:header,footer:footer))
    }
    func testReverseIntoPreviouslyCapturedContentDoesNotGrowThenForwardCanContinue() throws {
        let source=noise(),header=noise(height:12),footer=noise(height:10,seed:3)
        var session=CaptureScrollStitcher()
        var grown:CaptureScrollStitcher.Result?
        for start in [0,80,160] {grown=try session.append(viewport(source,start,header:header,footer:footer))}
        let reverse=try session.append(viewport(source,80,header:header,footer:footer))
        XCTAssertTrue(reverse.duplicate);XCTAssertEqual(reverse.viewportOffset,80);try equal(reverse.image,XCTUnwrap(grown).image)
        let forward=try session.append(viewport(source,240,header:header,footer:footer))
        XCTAssertFalse(forward.duplicate);XCTAssertEqual(forward.viewportOffset,240)
        try equal(forward.image,compose(XCTUnwrap(source.cropping(to:CGRect(x:0,y:0,width:80,height:368))),header:header,footer:footer))
    }
    func testReversePastStartingViewportPrependsWithoutLosingOriginalPixels() throws {
        let source=noise(),header=noise(height:12),footer=noise(height:10,seed:3)
        var session=CaptureScrollStitcher()
        _=try session.append(viewport(source,160,header:header,footer:footer))
        _=try session.append(viewport(source,80,header:header,footer:footer))
        let result=try session.append(viewport(source,0,header:header,footer:footer))
        XCTAssertFalse(result.duplicate);XCTAssertEqual(result.viewportOffset,0)
        try equal(result.image,compose(XCTUnwrap(source.cropping(to:CGRect(x:0,y:0,width:80,height:288))),header:header,footer:footer))
    }
    func testHorizontalFixedEdgesUseSameMatchingAndPixelOrder() throws {
        let source=noise(),header=noise(height:12),footer=noise(height:10,seed:3)
        var session=CaptureScrollStitcher(direction:.horizontal)
        _=try session.append(CaptureStitcher.transposed(viewport(source,0,header:header,footer:footer)))
        let result=try session.append(CaptureStitcher.transposed(viewport(source,80,header:header,footer:footer)))
        XCTAssertEqual(result.fixedLeading,12);XCTAssertEqual(result.fixedTrailing,10)
        let expected=try compose(XCTUnwrap(source.cropping(to:CGRect(x:0,y:0,width:80,height:208))),header:header,footer:footer)
        try equal(result.image,CaptureStitcher.transposed(expected))
    }
    func testManualFixedBarsCanChangeTheirPixelsWithoutCorruptingBody() throws {
        let source=noise(),header=noise(height:12),footer=noise(height:10,seed:3),changedHeader=noise(height:12,seed:11),changedFooter=noise(height:10,seed:12)
        var session=CaptureScrollStitcher(detectFixedEdges:false,leadingInset:12,trailingInset:10)
        _=try session.append(viewport(source,0,header:header,footer:footer))
        let result=try session.append(viewport(source,80,header:changedHeader,footer:changedFooter))
        try equal(result.image,compose(XCTUnwrap(source.cropping(to:CGRect(x:0,y:0,width:80,height:208))),header:header,footer:changedFooter))
    }
    func testRejectedFrameDoesNotChangeSessionAndNoFixedEdgesStillWork() throws {
        let source=noise();var session=CaptureScrollStitcher()
        _=try session.append(viewport(source,0,header:nil,footer:nil))
        XCTAssertThrowsError(try session.append(viewport(source,400,header:nil,footer:nil)))
        XCTAssertThrowsError(try session.append(noise(width:90,height:128)))
        let result=try session.append(viewport(source,80,header:nil,footer:nil))
        XCTAssertEqual(result.fixedLeading,0);XCTAssertEqual(result.fixedTrailing,0)
        try equal(result.image,XCTUnwrap(source.cropping(to:CGRect(x:0,y:0,width:80,height:208))))
    }
    func testInvalidFixedInsetsAndAmbiguousRepeatedContentAreRejected() throws {
        let source=noise(height:32)
        for edges in [(-1,0),(0,-1),(1,0),(Int.max,0)] {
            var session=CaptureScrollStitcher(detectFixedEdges:false,leadingInset:edges.0,trailingInset:edges.1)
            XCTAssertThrowsError(try session.append(source))
        }
        let period=noise(height:32),rows=try CaptureStitcher.pixels(period)
        let tiled=image(rows+rows+rows+rows+rows+rows,width:80,height:192)
        var session=CaptureScrollStitcher(detectFixedEdges:false)
        _=try session.append(viewport(tiled,0,header:nil,footer:nil))
        XCTAssertThrowsError(try session.append(viewport(tiled,16,header:nil,footer:nil)))
    }
    func testProjectionCollisionCannotSilentlyClassifyChangedPixelsAsDuplicate() throws {
        let source=noise(width:128,height:128);var bytes=try CaptureStitcher.pixels(source)
        for y in 0..<128 {for c in 0..<3 {bytes[(y*128+1)*4+c]=255-bytes[(y*128+1)*4+c]}}
        let changed=image(bytes,width:128,height:128)
        var session=CaptureScrollStitcher(detectFixedEdges:false)
        XCTAssertThrowsError(try CaptureStitcher.append(changed,to:source))
        _=try session.append(source);XCTAssertThrowsError(try session.append(changed))
        XCTAssertTrue(try session.append(source).duplicate)
    }
    @MainActor func testMostlyWhiteTextListWithFixedBarsPreservesEveryPixel() throws {
        _=NSApplication.shared
        let width=480,height=1200,ctx=try CaptureStitcher.context(width:width,height:height)
        ctx.setFillColor(NSColor.white.cgColor);ctx.fill(CGRect(x:0,y:0,width:width,height:height))
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:ctx,flipped:false)
        for row in 0..<30 {
            ("Folder item \(row) — status ready" as NSString).draw(at:CGPoint(x:20,y:height-row*40-30),withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:18,weight:.regular),.foregroundColor:NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState()
        let source=try XCTUnwrap(ctx.makeImage()),header=noise(width:width,height:32),footer=noise(width:width,height:24,seed:2)
        func frame(_ start:Int) throws -> CGImage {try compose(XCTUnwrap(source.cropping(to:CGRect(x:0,y:start,width:width,height:256))),header:header,footer:footer)}
        var session=CaptureScrollStitcher()
        _=try session.append(frame(0));let result=try session.append(frame(160))
        try equal(result.image,compose(XCTUnwrap(source.cropping(to:CGRect(x:0,y:0,width:width,height:416))),header:header,footer:footer))
    }
}
