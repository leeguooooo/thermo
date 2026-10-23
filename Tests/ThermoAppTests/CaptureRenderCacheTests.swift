import AppKit
import CaptureCore
import XCTest
@testable import ThermoApp

@MainActor final class CaptureRenderCacheTests:XCTestCase {
    private func model() throws -> CaptureEditorModel {
        _=NSApplication.shared
        let ctx=try XCTUnwrap(CGContext(data:nil,width:1024,height:768,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        for x in stride(from:0,to:1024,by:16) {
            ctx.setFillColor((x%32 == 0 ? NSColor.orange : NSColor.blue).cgColor);ctx.fill(CGRect(x:x,y:0,width:16,height:768))
        }
        let model=CaptureEditorModel(image:try XCTUnwrap(ctx.makeImage()))
        model.document.append(.init(tool:.mosaic,points:[CGPoint(x:100,y:100),CGPoint(x:700,y:500)]))
        return model
    }
    private func draw(_ canvas:CaptureCanvas.Canvas) throws -> Data {
        let ctx=try XCTUnwrap(CGContext(data:nil,width:512,height:384,bitsPerComponent:8,bytesPerRow:512*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:ctx,flipped:false)
        canvas.draw(canvas.bounds);NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(ctx.makeImage()?.dataProvider?.data) as Data
    }
    func testPanZoomSelectionAndMarqueeReuseCompositeWithIdenticalWindowPixels() throws {
        let model=try model(),cache=CaptureRenderCache(byteLimit:16*1024*1024)
        var cachedRenders=0,baselineRenders=0
        let cached=CaptureCanvas.Canvas(model:model,cache:cache,render:{doc,draft,replacements in cachedRenders+=1;return try doc.rendered(adding:draft,replacements:replacements)})
        let baseline=CaptureCanvas.Canvas(model:model,cache:CaptureRenderCache(byteLimit:0),render:{doc,draft,replacements in baselineRenders+=1;return try doc.rendered(adding:draft,replacements:replacements)})
        cached.frame=CGRect(x:0,y:0,width:512,height:384);baseline.frame=cached.frame;model.tool = .select
        for step in 0..<12 {
            model.pan=CGPoint(x:step*2,y:step);model.zoom=1+Double(step)*0.03
            model.selectAnnotations(step%2 == 0 ? [0] : [])
            let marquee=step%3 == 0 ? CGRect(x:20,y:20,width:400,height:300) : nil
            cached.marqueeRect=marquee;baseline.marqueeRect=marquee
            XCTAssertTrue(try draw(cached).elementsEqual(draw(baseline)),"Cached redraw pixels changed at step \(step)")
        }
        XCTAssertEqual(cachedRenders,1);XCTAssertEqual(baselineRenders,12)
        XCTAssertGreaterThan(cache.cachedBytes,0);XCTAssertLessThanOrEqual(cache.cachedBytes,16*1024*1024)
    }
    func testMutationUndoPreviewCancellationAndAppearanceNeverReturnStalePixels() throws {
        let model=try model(),cache=CaptureRenderCache();var renders=0
        let canvas=CaptureCanvas.Canvas(model:model,cache:cache,render:{doc,draft,replacements in renders+=1;return try doc.rendered(adding:draft,replacements:replacements)})
        let original=try canvas.renderedImage()
        _=try canvas.renderedImage();XCTAssertEqual(renders,1)
        model.tool = .select;model.selectAnnotation(0);canvas.selectionRevision=model.revision
        canvas.selectionPreview=[0:model.document.annotations[0].moved(dx:100,dy:100)]
        let preview=try canvas.renderedImage();XCTAssertEqual(renders,2)
        XCTAssertNotEqual(try CaptureDocument(image:preview).data(),try CaptureDocument(image:original).data())
        canvas.cancelSelectionGesture();let cancelled=try canvas.renderedImage()
        XCTAssertTrue(cancelled === original);XCTAssertEqual(renders,2)
        model.document.append(.init(tool:.redact,points:[.zero,CGPoint(x:300,y:300)]))
        let edited=try canvas.renderedImage();XCTAssertEqual(renders,3)
        XCTAssertNotEqual(try CaptureDocument(image:edited).data(),try CaptureDocument(image:original).data())
        model.undoAnnotation();let undone=try canvas.renderedImage();XCTAssertEqual(renders,4)
        XCTAssertEqual(try CaptureDocument(image:undone).data(),try CaptureDocument(image:original).data())
        canvas.viewDidChangeEffectiveAppearance();_=try canvas.renderedImage();XCTAssertEqual(renders,5)
    }
    func testLRUBudgetOversizedEntriesSourceIdentityAndFailure() throws {
        let image=try model().document.rendered(),cost=image.bytesPerRow*image.height
        let cache=CaptureRenderCache(byteLimit:cost*2),sources=[NSObject(),NSObject()],a=UUID(),b=UUID(),c=UUID()
        var renders=0
        func get(_ owner:UUID,_ revision:Int=0,_ source:Int=0) throws -> CGImage {
            try cache.image(owner:owner,source:ObjectIdentifier(sources[source]),revision:revision) {renders+=1;return image}
        }
        _=try get(a);_=try get(b);_=try get(a);XCTAssertEqual(renders,2)
        _=try get(c);XCTAssertEqual(cache.count,2);XCTAssertEqual(cache.cachedBytes,cost*2)
        _=try get(b);XCTAssertEqual(renders,4)
        _=try get(b,0,1);XCTAssertEqual(renders,5)
        enum Failure:Error {case fixture}
        XCTAssertThrowsError(try cache.image(owner:b,source:ObjectIdentifier(sources[1]),revision:1) {throw Failure.fixture})
        XCTAssertEqual(cache.count,1);XCTAssertEqual(cache.cachedBytes,cost)
        cache.remove(owner:c);XCTAssertEqual(cache.cachedBytes,0)
        let small=CaptureRenderCache(byteLimit:cost-1)
        for _ in 0..<2 {_=small.image(owner:a,source:ObjectIdentifier(sources[0]),revision:0){renders+=1;return image}}
        XCTAssertEqual(small.cachedBytes,0);XCTAssertEqual(small.count,0);XCTAssertEqual(renders,7)
    }
    func testHiddenClosingAndDeallocatedCanvasesReleaseTheirImages() throws {
        let model=try model(),cache=CaptureRenderCache()
        var canvas:CaptureCanvas.Canvas?=CaptureCanvas.Canvas(model:model,cache:cache)
        let window=NSWindow(contentRect:CGRect(x:-20000,y:-20000,width:512,height:384),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=canvas
        _=try canvas?.renderedImage();XCTAssertGreaterThan(cache.cachedBytes,0)
        NotificationCenter.default.post(name:NSWindow.didChangeOcclusionStateNotification,object:window)
        XCTAssertEqual(cache.cachedBytes,0)
        _=try canvas?.renderedImage();window.close();XCTAssertEqual(cache.cachedBytes,0)
        window.contentView=nil;canvas=nil
        weak var deallocated:CaptureCanvas.Canvas?
        try autoreleasepool {
            let detached=CaptureCanvas.Canvas(model:model,cache:cache);deallocated=detached
            _=try detached.renderedImage();XCTAssertGreaterThan(cache.cachedBytes,0)
        }
        XCTAssertNil(deallocated);XCTAssertEqual(cache.cachedBytes,0)
    }
    func testZoomedCanvasNeverPaintsOutsideItsBounds() throws {
        let model=try model();model.zoom=2
        let canvas=CaptureCanvas.Canvas(model:model,cache:CaptureRenderCache());canvas.frame=CGRect(x:0,y:0,width:512,height:384)
        let ctx=try XCTUnwrap(CGContext(data:nil,width:600,height:500,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(NSColor.magenta.cgColor);ctx.fill(CGRect(x:0,y:0,width:600,height:500))
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:ctx,flipped:false)
        canvas.draw(canvas.bounds);NSGraphicsContext.restoreGraphicsState()
        let rep=NSBitmapImageRep(cgImage:try XCTUnwrap(ctx.makeImage()))
        let outside=try XCTUnwrap(rep.colorAt(x:550,y:250)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(outside.redComponent,1,accuracy:0.001);XCTAssertEqual(outside.greenComponent,0,accuracy:0.001);XCTAssertEqual(outside.blueComponent,1,accuracy:0.001)
        XCTAssertNotEqual(rep.colorAt(x:250,y:250)?.usingColorSpace(.deviceRGB),outside)
    }
}
