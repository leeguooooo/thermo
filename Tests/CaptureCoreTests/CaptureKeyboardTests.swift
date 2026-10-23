import AppKit
import AVFoundation
import XCTest
@testable import CaptureCore

final class CaptureKeyboardTests:XCTestCase {
    private let fixtures=CaptureArchiveFixtures()
    private func time(_ value:Double) -> CMTime { CMTime(seconds:value,preferredTimescale:60000) }
    private func root() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-keyboard-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        addTeardownBlock { try FileManager.default.removeItem(at:root) };return root
    }
    private func archive(mode:CaptureKeyMode? = .all) throws -> CaptureFrameArchive {
        try CaptureFrameArchive(root:root().appendingPathComponent("frames"),header:.init(width:320,height:240,fps:5,keyboardCapture:mode))
    }
    private func buffer() throws -> CVPixelBuffer {
        var result:CVPixelBuffer?;CVPixelBufferCreate(kCFAllocatorDefault,320,240,kCVPixelFormatType_32BGRA,[kCVPixelBufferCGImageCompatibilityKey:true,kCVPixelBufferCGBitmapContextCompatibilityKey:true] as CFDictionary,&result)
        let buffer=try XCTUnwrap(result);CVPixelBufferLockBaseAddress(buffer,[]);defer { CVPixelBufferUnlockBaseAddress(buffer,[]) }
        let ctx=try XCTUnwrap(CGContext(data:CVPixelBufferGetBaseAddress(buffer),width:320,height:240,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(buffer),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue))
        ctx.setFillColor(NSColor.blue.cgColor);ctx.fill(CGRect(x:0,y:0,width:320,height:240));return buffer
    }
    private func png(_ image:CGImage) throws -> Data { try CaptureDocument(image:image).data() }
    func testCaptureIsExplicitAndShortcutsOnlyDoesNotStoreTyping() async throws {
        let disabled=try archive(mode:nil);XCTAssertTrue(try disabled.appendVideo(buffer(),at:time(100)))
        XCTAssertFalse(try disabled.recordKey(label:"A",shortcut:false,at:time(100.1)))
        _=try await disabled.finish(at:time(101));XCTAssertTrue(try CaptureFrameArchiveSource.load(disabled.root).keys.isEmpty)
        let shortcuts=try archive(mode:.shortcuts);XCTAssertTrue(try shortcuts.appendVideo(buffer(),at:time(100)))
        XCTAssertFalse(try shortcuts.recordKey(label:"A",shortcut:false,at:time(100.1)))
        XCTAssertTrue(try shortcuts.recordKey(label:"⌘C",shortcut:true,at:time(100.2)))
        _=try await shortcuts.finish(at:time(101));let loaded=try CaptureFrameArchiveSource.load(shortcuts.root)
        XCTAssertEqual(loaded.keys.map(\.label),["⌘C"])
    }
    func testKeysFollowPauseTimelineAndCancelFlushesJournal() async throws {
        let archive=try archive();XCTAssertTrue(try archive.appendVideo(buffer(),at:time(100)))
        XCTAssertTrue(try archive.recordKey(label:"⌘C",shortcut:true,at:time(100.2)))
        archive.pause(at:time(101));XCTAssertFalse(try archive.recordKey(label:"X",shortcut:false,at:time(104)))
        archive.resume(at:time(106));XCTAssertTrue(try archive.recordKey(label:"Y",shortcut:false,at:time(107)))
        await archive.cancelAndWait();let source=try CaptureFrameArchiveSource.load(archive.root)
        XCTAssertEqual(source.keys.map(\.time),[0.2,2]);XCTAssertEqual(source.keys.map(\.label),["⌘C","Y"])
    }
    func testOverlayCanHideFilterMoveExpireAndLeaveSourceUntouched() async throws {
        let archive=try archive();XCTAssertTrue(try archive.appendVideo(buffer(),at:time(100)))
        XCTAssertTrue(try archive.recordKey(label:"A",shortcut:false,at:time(100.5)))
        XCTAssertTrue(try archive.recordKey(label:"⌘C",shortcut:true,at:time(102)))
        _=try await archive.finish(at:time(104));let source=try CaptureFrameArchiveSource.load(archive.root),original=try Data(contentsOf:source.frameURL(0))
        var edits=CaptureNormalEdits(),keys=CaptureKeyboardEdits();edits.showCursor=false;keys.mode = .hidden;edits.keyboard=keys
        let clean=try png(CaptureNormalRenderer(source:source,edits:edits).image(at:0.7))
        keys.mode = .shortcuts;edits.keyboard=keys
        XCTAssertEqual(try png(CaptureNormalRenderer(source:source,edits:edits).image(at:0.7)),clean)
        XCTAssertNotEqual(try png(CaptureNormalRenderer(source:source,edits:edits).image(at:2.2)),clean)
        keys.mode = .all;edits.keyboard=keys
        let all=try CaptureNormalRenderer(source:source,edits:edits)
        XCTAssertNotEqual(try png(all.image(at:0.7)),clean);XCTAssertEqual(try png(all.image(at:3.8)),clean)
        keys.top=true;edits.keyboard=keys
        XCTAssertNotEqual(try png(CaptureNormalRenderer(source:source,edits:edits).image(at:0.7)),try png(all.image(at:0.7)))
        XCTAssertEqual(try Data(contentsOf:source.frameURL(0)),original)
    }
    func testOldArchivesAndOldEditsDoNotRequireKeyboardData() async throws {
        let archive=try archive();XCTAssertTrue(try archive.appendVideo(buffer(),at:time(100)));_=try await archive.finish(at:time(101))
        try FileManager.default.removeItem(at:archive.root.appendingPathComponent("keyboard.jsonl"))
        XCTAssertTrue(try CaptureFrameArchiveSource.load(archive.root).keys.isEmpty)
        let edits=CaptureNormalEdits();try edits.save(to:archive.root)
        XCTAssertNil(try CaptureNormalEdits.load(from:archive.root).keyboard)
        var invalid=edits,keyboard=CaptureKeyboardEdits();keyboard.hold = .nan;invalid.keyboard=keyboard;XCTAssertFalse(invalid.valid)
    }
    func testDamagedKeyJournalDoesNotSilentlyCorruptRecordedTimeline() async throws {
        let archive=try archive();XCTAssertTrue(try archive.appendVideo(buffer(),at:time(100)))
        XCTAssertTrue(try archive.recordKey(label:"⌘C",shortcut:true,at:time(100.2)))
        XCTAssertThrowsError(try archive.recordKey(label:"bad\nkey",shortcut:true,at:time(100.3)))
        _=try await archive.finish(at:time(101))
        let journal=archive.root.appendingPathComponent("keyboard.jsonl"),original=try Data(contentsOf:journal)
        var torn=original;torn.append(contentsOf:Data("{\"time\":".utf8));try torn.write(to:journal)
        XCTAssertEqual(try CaptureFrameArchiveSource.load(archive.root).keys.count,1)
        var corrupt=original;corrupt.append(contentsOf:Data("bad\n{}".utf8));try corrupt.write(to:journal)
        XCTAssertThrowsError(try CaptureFrameArchiveSource.load(archive.root))
        try original.write(to:journal)
    }
}

extension CaptureKeyboardTests {
    func testTrimAndSpeedPreserveKeyboardTimingInEveryExportFormat() async throws {
        let archive=try archive();XCTAssertTrue(try archive.appendVideo(buffer(),at:time(100)))
        XCTAssertTrue(try archive.recordKey(label:"⌘C",shortcut:true,at:time(100.5)))
        XCTAssertTrue(try archive.recordKey(label:"A",shortcut:false,at:time(101.5)))
        _=try await archive.finish(at:time(103));let source=try CaptureFrameArchiveSource.load(archive.root)
        var edits=CaptureNormalEdits(),keys=CaptureKeyboardEdits();keys.mode = .all;keys.hold=0.4;keys.scale=0.5;edits.keyboard=keys
        let outputRoot=archive.root.deletingLastPathComponent()
        func box(_ image:CGImage) throws -> Bool {
            let color=try fixtures.color(image,x:160,y:228)
            return color.blueComponent < 0.65 || color.redComponent > 0.6
        }
        for format in CaptureMovieFormat.allCases {
            var options=CaptureMovieExport.Options();options.format=format;options.fps=5;options.start=0.5;options.end=2.5;options.speed=2;options.maxDimension=320
            let output=outputRoot.appendingPathComponent("keys."+format.fileExtension)
            try await CaptureNormalExport.export(source:source,to:output,edits:edits,options:options)
            func image(at value:Double) throws -> CGImage {
                if format == .mp4 {
                    let generator=AVAssetImageGenerator(asset:AVURLAsset(url:output));generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
                    return try generator.copyCGImage(at:time(value),actualTime:nil)
                }
                let input=try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL,nil)),count=CGImageSourceGetCount(input)
                var position=0.0
                for index in 0..<count {
                    let properties=try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(input,index,nil) as? [String:Any])
                    let key=format == .gif ? kCGImagePropertyGIFDictionary as String : format == .apng ? kCGImagePropertyPNGDictionary as String : "{WebP}"
                    let timing=try XCTUnwrap(properties[key] as? [String:Any]),delay=try XCTUnwrap(timing["UnclampedDelayTime"] as? Double ?? timing["DelayTime"] as? Double)
                    if position+delay > value+0.00001 || index == count-1 { return try XCTUnwrap(CGImageSourceCreateImageAtIndex(input,index,nil)) };position += delay
                }
                throw CaptureFailure.invalidImage
            }
            XCTAssertTrue(try box(image(at:0)),format.rawValue)
            XCTAssertFalse(try box(image(at:0.2)),format.rawValue)
            XCTAssertFalse(try box(image(at:0.4)),format.rawValue)
            XCTAssertTrue(try box(image(at:0.6)),format.rawValue)
            XCTAssertFalse(try box(image(at:0.8)),format.rawValue)
        }
    }
}
