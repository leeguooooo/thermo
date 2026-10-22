import AppKit
import AVFoundation
import XCTest
@testable import CaptureCore

struct CaptureArchiveFixtures {
    func frame(_ color:NSColor = .blue,split:Bool = false) throws -> CVPixelBuffer {
        var result:CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault,160,120,kCVPixelFormatType_32BGRA,[kCVPixelBufferCGImageCompatibilityKey:true,kCVPixelBufferCGBitmapContextCompatibilityKey:true] as CFDictionary,&result),kCVReturnSuccess)
        let buffer=try XCTUnwrap(result)
        CVPixelBufferLockBaseAddress(buffer,[]);defer { CVPixelBufferUnlockBaseAddress(buffer,[]) }
        let ctx=try XCTUnwrap(CGContext(data:CVPixelBufferGetBaseAddress(buffer),width:160,height:120,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(buffer),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue))
        ctx.setFillColor(color.cgColor);ctx.fill(CGRect(x:0,y:0,width:160,height:120))
        if split { ctx.setFillColor(NSColor.red.cgColor);ctx.fill(CGRect(x:0,y:60,width:160,height:60)) }
        return buffer
    }
    func color(_ image:CGImage,x:Int,y:Int) throws -> NSColor { try XCTUnwrap(NSBitmapImageRep(cgImage:image).colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB)) }
}

final class CaptureFrameArchiveTests:XCTestCase {
    let fixtures=CaptureArchiveFixtures()
    func time(_ seconds:Double) -> CMTime { CMTime(seconds:seconds,preferredTimescale:60000) }
    func directory() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-frame-archive-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        addTeardownBlock { try FileManager.default.removeItem(at:root) };return root
    }
    func archive(root:URL? = nil) throws -> CaptureFrameArchive { try CaptureFrameArchive(root:(root ?? directory()).appendingPathComponent("frames"),header:.init(width:160,height:120,fps:5)) }
    func testOriginalFramesAndPauseTimelineSurviveReload() async throws {
        let archive=try archive()
        XCTAssertTrue(try archive.appendVideo(fixtures.frame(.blue,split:true),at:time(100)))
        archive.recordPointer(.init(x:0.2,y:0.3),at:time(100.5))
        archive.pause(at:time(101));XCTAssertFalse(try archive.appendVideo(fixtures.frame(),at:time(103)))
        archive.recordPointer(.init(x:0.9,y:0.9),at:time(104))
        archive.resume(at:time(106));XCTAssertTrue(try archive.appendVideo(fixtures.frame(.green),at:time(107)))
        _=try await archive.finish(at:time(108))
        let source=try CaptureFrameArchiveSource.load(archive.root)
        XCTAssertEqual(source.frames.count,2);XCTAssertEqual(source.frames[1].time,2,accuracy:0.0001)
        XCTAssertEqual(source.pointers.count,1);XCTAssertEqual(source.duration,3,accuracy:0.0001)
        let original=try CaptureDocument.load(source.frameURL(0))
        XCTAssertGreaterThan(try fixtures.color(original,x:80,y:10).redComponent,0.9)
        XCTAssertGreaterThan(try fixtures.color(original,x:80,y:110).blueComponent,0.9)
    }
    func testCursorCanMoveAndBeRemovedWithoutChangingSourceFrame() async throws {
        let archive=try archive();XCTAssertTrue(try archive.appendVideo(fixtures.frame(),at:time(100)))
        archive.recordPointer(.init(x:0.25,y:0.75),at:time(100))
        archive.recordPointer(.init(x:0.75,y:0.75),at:time(101))
        _=try await archive.finish(at:time(102));let source=try CaptureFrameArchiveSource.load(archive.root)
        let original=try Data(contentsOf:source.frameURL(0))
        var edits=CaptureNormalEdits();edits.showClicks=false
        let visible=try CaptureNormalRenderer(source:source,edits:edits)
        XCTAssertGreaterThan(try fixtures.color(visible.image(at:0.2),x:45,y:40).redComponent,0.8)
        XCTAssertGreaterThan(try fixtures.color(visible.image(at:1.2),x:125,y:40).redComponent,0.8)
        XCTAssertLessThan(try fixtures.color(visible.image(at:1.2),x:45,y:40).redComponent,0.2)
        edits.showCursor=false
        let hidden=try CaptureNormalRenderer(source:source,edits:edits)
        XCTAssertLessThan(try fixtures.color(hidden.image(at:0.2),x:45,y:40).redComponent,0.2)
        XCTAssertEqual(try Data(contentsOf:source.frameURL(0)),original);XCTAssertEqual(source.frames.count,1)
    }
    func testCropAndTimedAnnotationsPersistWithoutBakingSource() async throws {
        let archive=try archive();XCTAssertTrue(try archive.appendVideo(fixtures.frame(.blue,split:true),at:time(100)))
        _=try await archive.finish(at:time(102));let source=try CaptureFrameArchiveSource.load(archive.root)
        var edits=CaptureNormalEdits();edits.showCursor=false;edits.crop=CGRect(x:0,y:0.5,width:1,height:0.5)
        let item=CaptureAnnotation(tool:.redact,points:[CGPoint(x:20,y:70),CGPoint(x:60,y:110)])
        edits.annotations=[CaptureVectorAnnotation(item,start:0.5,end:1.5)];try edits.save(to:archive.root)
        let restored=try CaptureNormalEdits.load(from:archive.root),renderer=try CaptureNormalRenderer(source:source,edits:restored)
        let early=try renderer.image(at:0.2),during=try renderer.image(at:1)
        XCTAssertEqual(early.height,60);XCTAssertGreaterThan(try fixtures.color(early,x:30,y:30).redComponent,0.9)
        XCTAssertLessThan(try fixtures.color(during,x:30,y:30).redComponent,0.05)
        XCTAssertGreaterThan(try fixtures.color(renderer.image(at:1.8),x:30,y:30).redComponent,0.9)
        XCTAssertEqual(try CaptureDocument.load(source.frameURL(0)).height,120)
    }
    func testTornJournalTailRecoversButCorruptMiddleAndSymlinksFail() async throws {
        let archive=try archive();XCTAssertTrue(try archive.appendVideo(fixtures.frame(),at:time(100)))
        _=try await archive.finish(at:time(101))
        let journal=archive.root.appendingPathComponent("frames.jsonl"),original=try Data(contentsOf:journal)
        var torn=original;torn.append(contentsOf:Data("{\"index\":".utf8));try torn.write(to:journal)
        XCTAssertEqual(try CaptureFrameArchiveSource.load(archive.root).frames.count,1)
        var corrupt=original;corrupt.append(contentsOf:Data("broken\n{\"index\":1}".utf8));try corrupt.write(to:journal)
        XCTAssertThrowsError(try CaptureFrameArchiveSource.load(archive.root))
        try original.write(to:journal)
        let outside=archive.root.deletingLastPathComponent().appendingPathComponent("outside.png")
        try FileManager.default.copyItem(at:archive.root.appendingPathComponent("00000000.png"),to:outside)
        try FileManager.default.removeItem(at:archive.root.appendingPathComponent("00000000.png"))
        try FileManager.default.createSymbolicLink(at:archive.root.appendingPathComponent("00000000.png"),withDestinationURL:outside)
        XCTAssertThrowsError(try CaptureFrameArchiveSource.load(archive.root));XCTAssertTrue(FileManager.default.fileExists(atPath:outside.path))
    }
    func testNormalDraftCanReopenWithoutAnyMovieProxy() async throws {
        let store=CaptureRecordingDraftStore(root:try directory().appendingPathComponent("drafts"))
        var draft=try store.create(mode:.normal)
        let archive=try CaptureFrameArchive(root:store.archive(draft.id),header:.init(width:160,height:120,fps:5))
        XCTAssertTrue(try archive.appendVideo(fixtures.frame(),at:time(100)));_=try await archive.finish(at:time(101))
        draft.status = .ready;try store.update(draft)
        XCTAssertFalse(FileManager.default.fileExists(atPath:store.movie(draft.id).path))
        XCTAssertEqual(try store.list().first?.effectiveMode,.normal)
        XCTAssertEqual(try CaptureFrameArchiveSource.load(store.archive(draft.id)).frames.count,1)
        let legacy=Data("{\"id\":\"\(UUID().uuidString)\",\"createdAt\":0,\"status\":\"ready\"}".utf8)
        XCTAssertEqual(try JSONDecoder().decode(CaptureRecordingDraft.self,from:legacy).effectiveMode,.quick)
    }
    func testInvalidEditDataIsRejectedBeforeRendering() async throws {
        let archive=try archive();XCTAssertTrue(try archive.appendVideo(fixtures.frame(),at:time(100)));_=try await archive.finish(at:time(101))
        let source=try CaptureFrameArchiveSource.load(archive.root)
        var edits=CaptureNormalEdits();edits.crop=CGRect(x:0,y:0,width:0,height:1)
        XCTAssertThrowsError(try edits.save(to:archive.root));XCTAssertThrowsError(try CaptureNormalRenderer(source:source,edits:edits))
    }
}

extension CaptureFrameArchiveTests {
    func testWatermarkProgressAndJPEGSourcesRemainEditable() async throws {
        let root=try directory(),archive=try CaptureFrameArchive(root:root.appendingPathComponent("frames"),header:.init(width:160,height:120,fps:5,codec:.jpeg),jpegQuality:0.9)
        XCTAssertTrue(try archive.appendVideo(fixtures.frame(),at:time(100)));_=try await archive.finish(at:time(102))
        let source=try CaptureFrameArchiveSource.load(archive.root),original=try Data(contentsOf:source.frameURL(0))
        XCTAssertEqual(Array(original.prefix(2)),[255,216])
        var edits=CaptureNormalEdits();edits.showCursor=false
        let clean=try CaptureDocument(image:CaptureNormalRenderer(source:source,edits:edits).image(at:1)).data()
        edits.watermark="QA"
        XCTAssertNotEqual(try CaptureDocument(image:CaptureNormalRenderer(source:source,edits:edits).image(at:1)).data(),clean)
        edits.watermark="";edits.progress = .remaining
        XCTAssertNotEqual(try CaptureDocument(image:CaptureNormalRenderer(source:source,edits:edits).image(at:1,progress:0.5,remaining:1)).data(),clean)
        XCTAssertEqual(try Data(contentsOf:source.frameURL(0)),original)
    }
}

extension CaptureFrameArchiveTests {
    func testCancelFlushesAcceptedFramesForRecovery() async throws {
        let archive=try archive();XCTAssertTrue(try archive.appendVideo(fixtures.frame(),at:time(100)))
        archive.recordPointer(.init(x:0.4,y:0.5),at:time(100.1))
        await archive.cancelAndWait()
        XCTAssertFalse(try archive.appendVideo(fixtures.frame(),at:time(101)))
        let recovered=try CaptureFrameArchiveSource.load(archive.root)
        XCTAssertEqual(recovered.frames.count,1);XCTAssertEqual(recovered.pointers.count,1)
        XCTAssertFalse(FileManager.default.fileExists(atPath:archive.root.appendingPathComponent("end.json").path))
    }
    func testFinishRetainsEveryAcceptedFrameDuringConcurrentCallbacks() async throws {
        let archive=try archive(),buffer=try fixtures.frame(),accepted=ArchiveAcceptedCounter(),group=DispatchGroup()
        XCTAssertTrue(try archive.appendVideo(buffer,at:time(100)));accepted.increment()
        for index in 1...20 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                if (try? archive.appendVideo(buffer,at:CMTime(seconds:100+Double(index)/10,preferredTimescale:60000))) == true { accepted.increment() }
            }
        }
        _=try await archive.finish(at:time(103));group.wait()
        let recovered=try CaptureFrameArchiveSource.load(archive.root)
        XCTAssertEqual(recovered.frames.count,accepted.value)
    }
}
private final class ArchiveAcceptedCounter:@unchecked Sendable {
    private let lock=NSLock()
    private var count=0
    func increment() { lock.lock();count += 1;lock.unlock() }
    var value:Int { lock.lock();defer { lock.unlock() };return count }
}
