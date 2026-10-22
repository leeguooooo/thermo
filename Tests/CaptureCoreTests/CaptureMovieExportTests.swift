import AVFoundation
import AppKit
import XCTest
@testable import CaptureCore

final class CaptureMovieExportTests:XCTestCase {
    private func time(_ seconds:Double) -> CMTime { CMTime(seconds:seconds,preferredTimescale:60000) }
    private func fixture() async throws -> (URL,URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-export-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
        addTeardownBlock { try FileManager.default.removeItem(at:directory) }
        let url = directory.appendingPathComponent("source.mp4"), writer = try CaptureMovieWriter(url:url,width:160,height:120,fps:5)
        for i in 0..<10 {
            var pixel:CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault,160,120,kCVPixelFormatType_32BGRA,[kCVPixelBufferCGImageCompatibilityKey:true,kCVPixelBufferCGBitmapContextCompatibilityKey:true] as CFDictionary,&pixel)
            let buffer = try XCTUnwrap(pixel)
            CVPixelBufferLockBaseAddress(buffer,[])
            let ctx = CGContext(data:CVPixelBufferGetBaseAddress(buffer),width:160,height:120,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(buffer),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.setFillColor((i%2 == 0 ? NSColor.red : NSColor.blue).cgColor); ctx.fill(CGRect(x:0,y:0,width:160,height:120))
            CVPixelBufferUnlockBaseAddress(buffer,[])
            while try !writer.appendVideo(buffer,at:time(100+Double(i)*0.2)) { try await Task.sleep(nanoseconds:1_000_000) }
        }
        _ = try await writer.finish(at:time(102)); return (directory,url)
    }
    func testTrimAndSpeedProducePlayableMP4() async throws {
        let (directory,source) = try await fixture(), output = directory.appendingPathComponent("trim.mp4")
        var options = CaptureMovieExport.Options(); options.start = 0.4; options.end = 1.6; options.speed = 2
        try await CaptureMovieExport.export(source:source,to:output,options:options)
        let duration = try await AVURLAsset(url:output).load(.duration)
        XCTAssertEqual(duration.seconds,0.6,accuracy:0.08)
        XCTAssertTrue(try AVAssetImageGenerator(asset:AVURLAsset(url:output)).copyCGImage(at:time(0.3),actualTime:nil).width > 0)
    }
    func testAnimatedFormatsContainFramesAndTiming() async throws {
        let (directory,source) = try await fixture()
        for format in [CaptureMovieFormat.gif,.apng,.webp] {
            let output = directory.appendingPathComponent("animation."+format.fileExtension)
            var options = CaptureMovieExport.Options(); options.format = format; options.fps = 5; options.maxDimension = 160
            try await CaptureMovieExport.export(source:source,to:output,options:options)
            let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL,nil))
            XCTAssertGreaterThan(CGImageSourceGetCount(imageSource),1,format.rawValue)
            let first = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource,0,nil))
            XCTAssertEqual(first.width,160); XCTAssertEqual(first.height,120)
            let second = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource,1,nil))
            let red = try XCTUnwrap(NSBitmapImageRep(cgImage:first).colorAt(x:80,y:60)?.usingColorSpace(.deviceRGB))
            let blue = try XCTUnwrap(NSBitmapImageRep(cgImage:second).colorAt(x:80,y:60)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(red.redComponent,0.7,format.rawValue); XCTAssertGreaterThan(blue.blueComponent,0.7,format.rawValue)
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(imageSource,0,nil) as? [String:Any])
            let containerKey = format == .gif ? kCGImagePropertyGIFDictionary as String : format == .apng ? kCGImagePropertyPNGDictionary as String : "{WebP}"
            let timing = properties[containerKey] as? [String:Any]
            let delay = timing?["UnclampedDelayTime"] as? Double ?? timing?["DelayTime"] as? Double
            XCTAssertEqual(try XCTUnwrap(delay,format.rawValue),0.2,accuracy:0.02)
        }
    }
    func testInvalidTrimPreservesExistingDestination() async throws {
        let (directory,source) = try await fixture(), output = directory.appendingPathComponent("existing.mp4")
        let original = Data("keep me".utf8); try original.write(to:output)
        var options = CaptureMovieExport.Options(); options.start = 2; options.end = 1
        do { try await CaptureMovieExport.export(source:source,to:output,options:options); XCTFail("Invalid trim accepted") } catch { }
        XCTAssertEqual(try Data(contentsOf:output),original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:directory.path).contains(where:{$0.hasPrefix(".thermo-export-")}))
    }
    func testSuccessfulExportReplacesExistingDestination() async throws {
        let (directory,source) = try await fixture(), output = directory.appendingPathComponent("existing.mp4")
        try Data("old destination".utf8).write(to:output)
        try await CaptureMovieExport.export(source:source,to:output,options:CaptureMovieExport.Options())
        let playable = try await AVURLAsset(url:output).load(.isPlayable)
        XCTAssertTrue(playable)
    }
}
