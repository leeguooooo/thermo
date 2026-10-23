import AppKit
import AVFoundation
import XCTest
@testable import CaptureCore

final class CaptureAnnotationMovieTests:XCTestCase {
    func testTemporalMosaicExportsFromRawFramesWithCropAndEraser() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-annotation-movie-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false);addTeardownBlock { try FileManager.default.removeItem(at:root) }
        let archive=try CaptureFrameArchive(root:root.appendingPathComponent("frames"),header:.init(width:160,height:120,fps:5))
        var pixel:CVPixelBuffer?;CVPixelBufferCreate(kCFAllocatorDefault,160,120,kCVPixelFormatType_32BGRA,[kCVPixelBufferCGImageCompatibilityKey:true,kCVPixelBufferCGBitmapContextCompatibilityKey:true] as CFDictionary,&pixel)
        let buffer=try XCTUnwrap(pixel);CVPixelBufferLockBaseAddress(buffer,[])
        let context=try XCTUnwrap(CGContext(data:CVPixelBufferGetBaseAddress(buffer),width:160,height:120,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(buffer),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue))
        for y in 0..<120 { for x in 0..<160 { context.setFillColor((x+y)%2 == 0 ? NSColor.red.cgColor : NSColor.blue.cgColor);context.fill(CGRect(x:x,y:y,width:1,height:1)) } }
        CVPixelBufferUnlockBaseAddress(buffer,[])
        XCTAssertTrue(try archive.appendVideo(buffer,at:CMTime(seconds:100,preferredTimescale:60000)));_=try await archive.finish(at:CMTime(seconds:102,preferredTimescale:60000))
        let source=try CaptureFrameArchiveSource.load(archive.root),original=try Data(contentsOf:source.frameURL(0))
        var edits=CaptureNormalEdits();edits.showCursor=false;edits.crop=CGRect(x:0.5,y:0,width:0.5,height:1)
        var mosaic=CaptureAnnotation(tool:.mosaic,points:[CGPoint(x:90,y:20),CGPoint(x:150,y:100)]);mosaic.options.strength=8
        edits.annotations=[CaptureVectorAnnotation(mosaic,start:0.5,end:1.5),CaptureVectorAnnotation(.init(tool:.eraserRect,points:[CGPoint(x:120,y:40),CGPoint(x:140,y:60)]),start:0.5,end:1.5)]
        var options=CaptureMovieExport.Options();options.fps=5
        let output=root.appendingPathComponent("effects.mp4");try await CaptureNormalExport.export(source:source,to:output,edits:edits,options:options)
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:output));generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        let middle=try generator.copyCGImage(at:CMTime(seconds:1,preferredTimescale:60000),actualTime:nil)
        XCTAssertEqual(middle.width,80)
        let rep=NSBitmapImageRep(cgImage:middle),color=try XCTUnwrap(rep.colorAt(x:20,y:80)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(color.redComponent,0.5,accuracy:0.12);XCTAssertEqual(color.blueComponent,0.5,accuracy:0.12)
        let early=try generator.copyCGImage(at:CMTime(seconds:0.2,preferredTimescale:60000),actualTime:nil)
        XCTAssertNotEqual(try CaptureDocument(image:early).data(),try CaptureDocument(image:middle).data())
        XCTAssertEqual(try Data(contentsOf:source.frameURL(0)),original)
    }
}
