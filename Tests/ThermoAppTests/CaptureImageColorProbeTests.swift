import AppKit
import CaptureCore
import XCTest
@testable import ThermoApp

@MainActor final class CaptureImageColorProbeTests:XCTestCase {
    private func fixture(cache:CaptureRenderCache = .shared,render:((CaptureDocument,CaptureAnnotation?,[Int:CaptureAnnotation])throws->CGImage)?=nil) throws -> (CaptureEditorModel,CaptureCanvas.Canvas,NSPasteboard) {
        _=NSApplication.shared
        let ctx=try XCTUnwrap(CGContext(data:nil,width:100,height:80,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(NSColor.red.cgColor);ctx.fill(CGRect(x:0,y:0,width:100,height:80));ctx.setFillColor(NSColor.blue.cgColor);ctx.fill(CGRect(x:50,y:40,width:50,height:40))
        let m=CaptureEditorModel(image:try XCTUnwrap(ctx.makeImage()));m.document.append(.init(tool:.redact,points:[CGPoint(x:10,y:10),CGPoint(x:30,y:30)]))
        let c=CaptureCanvas.Canvas(model:m,cache:cache,render:render ?? {try $0.rendered(adding:$1,replacements:$2)}),board=NSPasteboard.withUniqueName();m.copyPasteboard=board;c.frame=CGRect(x:0,y:0,width:100,height:80)
        return(m,c,board)
    }
    private func mouse(_ x:Double,_ y:Double,flags:NSEvent.ModifierFlags=[]) throws -> NSEvent {try XCTUnwrap(NSEvent.mouseEvent(with:.leftMouseDown,location:CGPoint(x:x,y:y),modifierFlags:flags,timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1))}
    private func key(_ code:UInt16,flags:NSEvent.ModifierFlags=[],type:NSEvent.EventType = .keyDown) throws -> NSEvent {try XCTUnwrap(NSEvent.keyEvent(with:type,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code))}
    func testLockedPickerReadsConfirmedAnnotationsCopiesFormatsAndDoesNotEdit() throws {
        let (m,c,b)=try fixture();defer{b.releaseGlobally()};let rev=m.revision,data=try m.document.data();m.locked=true;m.pickingImageColor=true
        XCTAssertTrue(c.sampleImageColor(at:CGPoint(x:20,y:20)));XCTAssertEqual(m.pickedImagePixel?.color.formatted(.hex),"#000000")
        c.mouseDown(with:try mouse(70,60));XCTAssertEqual(m.pickedImagePixel?.x,70);XCTAssertEqual(m.pickedImagePixel?.y,19);XCTAssertEqual(m.pickedImagePixel?.color.formatted(.hex),"#0000FF")
        c.keyDown(with:try key(8));XCTAssertEqual(b.string(forType:.string),"rgb(0, 0, 255)")
        c.keyDown(with:try key(51));XCTAssertEqual(m.revision,rev);XCTAssertEqual(try m.document.data(),data)
    }
    func testZoomAndPanMapToSourcePixelsAndOutsideViewDoesNotReplaceSelection() throws {
        let (m,c,b)=try fixture();defer{b.releaseGlobally()};m.pickingImageColor=true;m.zoom=2;m.pan=CGPoint(x:10,y:-5)
        XCTAssertTrue(c.sampleImageColor(at:CGPoint(x:80,y:55)));XCTAssertEqual(m.pickedImagePixel?.x,60);XCTAssertEqual(m.pickedImagePixel?.y,29)
        let selected=m.pickedImagePixel;XCTAssertFalse(c.sampleImageColor(at:CGPoint(x:200,y:200)));XCTAssertEqual(m.pickedImagePixel,selected)
    }
    func testOptionShiftCopyAndEscapeWorkThroughCanvasEvents() throws {
        let (m,c,b)=try fixture();defer{b.releaseGlobally()};let rev=m.revision
        c.mouseDown(with:try mouse(70,60,flags:.option));XCTAssertTrue(c.colorProbeActive);XCTAssertFalse(m.pickingImageColor)
        c.flagsChanged(with:try key(56,flags:[.option,.shift],type:.flagsChanged));XCTAssertEqual(m.pixelColorFormat,.hex)
        c.keyDown(with:try key(8,flags:[.option,.shift]));XCTAssertEqual(b.string(forType:.string),"#0000FF")
        c.keyDown(with:try key(53));XCTAssertFalse(c.colorProbeActive);XCTAssertNil(c.colorProbeImage);XCTAssertNil(m.pickedImagePixel);XCTAssertEqual(m.revision,rev)
    }
    func testImageAndModelChangesInvalidateSamplesAndEmptyCopyPreservesClipboard() throws {
        let (m,c,b)=try fixture();defer{b.releaseGlobally()};m.pickingImageColor=true;_ = c.sampleImageColor(at:CGPoint(x:70,y:60));XCTAssertNotNil(c.colorProbeImage)
        m.document.append(.init(tool:.rectangle,points:[.zero,CGPoint(x:5,y:5)]));c.reconcileColorProbe();XCTAssertNil(c.colorProbeImage);XCTAssertNil(m.pickedImagePixel)
        b.setString("keep",forType:.string);m.copyPixelColor();XCTAssertEqual(b.string(forType:.string),"keep")
        let (other,otherCanvas,otherBoard)=try fixture();defer{otherBoard.releaseGlobally()};other.pickingImageColor=true;c.model=other;_ = c.sampleImageColor(at:CGPoint(x:70,y:60));XCTAssertEqual(c.colorProbeSource,ObjectIdentifier(other));withExtendedLifetime(otherCanvas){}
    }
    func testLiveProbeReusesOneCompositionEvenOutsideStaticCacheBudgetAndReleasesOnExit() throws {
        var renders=0;let cache=CaptureRenderCache(byteLimit:0)
        let (m,c,b)=try fixture(cache:cache,render:{doc,draft,replacements in renders += 1;return try doc.rendered(adding:draft,replacements:replacements)});defer{b.releaseGlobally()};m.pickingImageColor=true
        _=c.sampleImageColor(at:CGPoint(x:20,y:20));_=c.sampleImageColor(at:CGPoint(x:70,y:60));_=try c.renderedImage()
        XCTAssertEqual(renders,1);XCTAssertEqual(cache.cachedBytes,0);XCTAssertNotNil(c.colorProbeImage)
        m.pickingImageColor=false;c.reconcileColorProbe();XCTAssertNil(c.colorProbeImage)
    }
    func testResigningWindowReleasesImageAndModifierStateWithoutLeavingShiftStuck() throws {
        let (m,c,b)=try fixture();defer{b.releaseGlobally()};m.pickingImageColor=true
        let window=NSWindow(contentRect:CGRect(x:0,y:0,width:100,height:80),styleMask:[],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=c
        _=c.sampleImageColor(at:CGPoint(x:70,y:60));c.colorOptionHeld=true;c.colorShiftHeld=true;XCTAssertNotNil(c.colorProbeImage)
        NotificationCenter.default.post(name:NSWindow.didResignKeyNotification,object:window)
        XCTAssertNil(c.colorProbeImage);XCTAssertFalse(c.colorOptionHeld);XCTAssertFalse(c.colorShiftHeld)
        c.flagsChanged(with:try key(56,flags:[.option,.shift],type:.flagsChanged));XCTAssertEqual(m.pixelColorFormat,.hex)
        window.contentView=nil;window.close()
    }
}
