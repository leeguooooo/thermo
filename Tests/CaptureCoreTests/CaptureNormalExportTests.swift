import AppKit
import AVFoundation
import XCTest
@testable import CaptureCore

final class CaptureNormalExportTests:XCTestCase {
    let fixtures=CaptureArchiveFixtures()
    func time(_ seconds:Double) -> CMTime { CMTime(seconds:seconds,preferredTimescale:60000) }
    func root() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-normal-export-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        addTeardownBlock { try FileManager.default.removeItem(at:root) };return root
    }
    func source(root:URL) async throws -> CaptureFrameArchiveSource {
        let archive=try CaptureFrameArchive(root:root.appendingPathComponent("frames"),header:.init(width:160,height:120,fps:5))
        XCTAssertTrue(try archive.appendVideo(fixtures.frame(.red),at:time(100)))
        XCTAssertTrue(try archive.appendVideo(fixtures.frame(.blue),at:time(101)))
        archive.recordPointer(.init(x:0.25,y:0.75),at:time(100));archive.recordPointer(.init(x:0.75,y:0.75),at:time(101))
        _=try await archive.finish(at:time(102));return try CaptureFrameArchiveSource.load(archive.root)
    }
    func testMP4RendersRawFramesWithCropAndTimedRedaction() async throws {
        let root=try root(),source=try await source(root:root)
        var edits=CaptureNormalEdits();edits.showCursor=false;edits.crop=CGRect(x:0,y:0,width:0.5,height:1)
        edits.annotations=[CaptureVectorAnnotation(.init(tool:.redact,points:[.zero,CGPoint(x:80,y:120)]),start:1,end:2)]
        var options=CaptureMovieExport.Options();options.fps=5;options.start=0.2;options.end=1.8
        let output=root.appendingPathComponent("crop.mp4")
        try await CaptureNormalExport.export(source:source,to:output,edits:edits,options:options)
        let asset=AVURLAsset(url:output),duration=try await asset.load(.duration)
        XCTAssertEqual(duration.seconds,1.6,accuracy:0.05)
        let generator=AVAssetImageGenerator(asset:asset)
        let early=try generator.copyCGImage(at:time(0.2),actualTime:nil),late=try generator.copyCGImage(at:time(1.2),actualTime:nil)
        XCTAssertEqual(early.width,80);XCTAssertEqual(early.height,120)
        XCTAssertGreaterThan(try fixtures.color(early,x:40,y:40).redComponent,0.7)
        XCTAssertLessThan(try fixtures.color(late,x:40,y:40).blueComponent,0.1)
        XCTAssertEqual(try CaptureDocument.load(source.frameURL(1)).width,160)
    }
    func testAnimationsEncodeRawPixelsAndCanHideCapturedPointer() async throws {
        let root=try root(),source=try await source(root:root)
        var edits=CaptureNormalEdits();edits.showCursor=false
        for format in [CaptureMovieFormat.gif,.apng,.webp] {
            var options=CaptureMovieExport.Options();options.format=format;options.fps=5;options.maxDimension=160
            let output=root.appendingPathComponent("raw."+format.fileExtension)
            try await CaptureNormalExport.export(source:source,to:output,edits:edits,options:options)
            let images=try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL,nil)),count=CGImageSourceGetCount(images)
            XCTAssertGreaterThanOrEqual(count,2)
            let first=try XCTUnwrap(CGImageSourceCreateImageAtIndex(images,0,nil)),last=try XCTUnwrap(CGImageSourceCreateImageAtIndex(images,count-1,nil))
            XCTAssertGreaterThan(try fixtures.color(first,x:45,y:40).redComponent,0.8)
            XCTAssertLessThan(try fixtures.color(first,x:45,y:40).greenComponent,0.2)
            XCTAssertGreaterThan(try fixtures.color(last,x:125,y:40).blueComponent,0.8)
            XCTAssertLessThan(try fixtures.color(last,x:125,y:40).redComponent,0.2)
        }
    }
    func audio(at seconds:Double) throws -> CMSampleBuffer {
        var description=AudioStreamBasicDescription(mSampleRate:48000,mFormatID:kAudioFormatLinearPCM,mFormatFlags:kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked,mBytesPerPacket:8,mFramesPerPacket:1,mBytesPerFrame:8,mChannelsPerFrame:2,mBitsPerChannel:32,mReserved:0)
        var format:CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator:kCFAllocatorDefault,asbd:&description,layoutSize:0,layout:nil,magicCookieSize:0,magicCookie:nil,extensions:nil,formatDescriptionOut:&format),noErr)
        let values=(0..<4800).flatMap { i -> [Float] in let value=Float(sin(Double(i)*2*Double.pi*440/48000))*0.2;return [value,value] }
        var block:CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator:kCFAllocatorDefault,memoryBlock:nil,blockLength:values.count*4,blockAllocator:kCFAllocatorDefault,customBlockSource:nil,offsetToData:0,dataLength:values.count*4,flags:0,blockBufferOut:&block),noErr)
        let data=try XCTUnwrap(block)
        values.withUnsafeBytes { _=CMBlockBufferReplaceDataBytes(with:$0.baseAddress!,blockBuffer:data,offsetIntoDestination:0,dataLength:$0.count) }
        var timing=CMSampleTimingInfo(duration:CMTime(value:1,timescale:48000),presentationTimeStamp:time(seconds),decodeTimeStamp:.invalid),sample:CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator:kCFAllocatorDefault,dataBuffer:data,formatDescription:format!,sampleCount:4800,sampleTimingEntryCount:1,sampleTimingArray:&timing,sampleSizeEntryCount:0,sampleSizeArray:nil,sampleBufferOut:&sample),noErr)
        return try XCTUnwrap(sample)
    }
    func testPCMSourceIsTrimmedScaledAndMixedWithoutBakingVolume() async throws {
        let root=try root(),archive=try CaptureFrameArchive(root:root.appendingPathComponent("frames"),header:.init(width:160,height:120,fps:5))
        XCTAssertTrue(try archive.appendVideo(fixtures.frame(.white),at:time(100)))
        for packet in 0..<20 { try archive.appendAudio(audio(at:100+Double(packet)/10)) }
        _=try await archive.finish(at:time(102));let source=try CaptureFrameArchiveSource.load(archive.root)
        XCTAssertNotNil(source.audioURL)
        var edits=CaptureNormalEdits();edits.showCursor=false;edits.systemVolume=0.25
        var options=CaptureMovieExport.Options();options.fps=5;options.start=0.2;options.end=1.8
        let output=root.appendingPathComponent("mixed.mp4")
        try await CaptureNormalExport.export(source:source,to:output,edits:edits,options:options)
        let asset=AVURLAsset(url:output),tracks=try await asset.loadTracks(withMediaType:.audio)
        XCTAssertEqual(tracks.count,1)
        let reader=try AVAssetReader(asset:asset),pcm=AVAssetReaderTrackOutput(track:tracks[0],outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVLinearPCMIsFloatKey:true,AVLinearPCMBitDepthKey:32,AVLinearPCMIsNonInterleaved:false])
        guard reader.canAdd(pcm) else { XCTFail("Unable to decode mixed audio");return };reader.add(pcm);XCTAssertTrue(reader.startReading())
        var count=0,energy=0.0
        while let sample=pcm.copyNextSampleBuffer(),let data=CMSampleBufferGetDataBuffer(sample) {
            let length=CMBlockBufferGetDataLength(data);var values=[Float](repeating:0,count:length/4)
            XCTAssertEqual(values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(data,atOffset:0,dataLength:length,destination:$0.baseAddress!) },noErr)
            for value in values { energy += Double(value*value) };count += values.count
        }
        XCTAssertEqual(reader.status,.completed);XCTAssertEqual(Double(count)/2/48000,1.6,accuracy:0.1)
        XCTAssertGreaterThan(sqrt(energy/Double(max(1,count))),0.015);XCTAssertLessThan(sqrt(energy/Double(max(1,count))),0.06)
        let original=try AVAudioFile(forReading:try XCTUnwrap(source.audioURL))
        XCTAssertEqual(original.length,96000)
    }
    func testInvalidOutputOrBrokenSourcePreservesExistingFile() async throws {
        let root=try root(),source=try await source(root:root),output=root.appendingPathComponent("existing.mp4")
        let keep=Data("previous destination".utf8);try keep.write(to:output)
        do { try await CaptureNormalExport.export(source:source,to:source.frameURL(0),edits:CaptureNormalEdits(),options:CaptureMovieExport.Options());XCTFail("Archive overwrite accepted") } catch { }
        try FileManager.default.removeItem(at:source.frameURL(0))
        do { try await CaptureNormalExport.export(source:source,to:output,edits:CaptureNormalEdits(),options:CaptureMovieExport.Options());XCTFail("Missing source accepted") } catch { }
        XCTAssertEqual(try Data(contentsOf:output),keep)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:root.path).contains { $0.hasPrefix(".thermo-normal-export-") })
    }
}

extension CaptureNormalExportTests {
    func testShortRecordingIsNotExtendedToFullFrameInterval() async throws {
        let root=try root(),archive=try CaptureFrameArchive(root:root.appendingPathComponent("frames"),header:.init(width:160,height:120,fps:5))
        XCTAssertTrue(try archive.appendVideo(fixtures.frame(),at:time(100)))
        _=try await archive.finish(at:time(100.01));let source=try CaptureFrameArchiveSource.load(archive.root)
        XCTAssertEqual(source.duration,0.01,accuracy:0.0001)
        var options=CaptureMovieExport.Options();options.fps=5
        let output=root.appendingPathComponent("short.mp4")
        try await CaptureNormalExport.export(source:source,to:output,edits:CaptureNormalEdits(),options:options)
        let duration=try await AVURLAsset(url:output).load(.duration)
        XCTAssertEqual(duration.seconds,0.01,accuracy:0.005)
    }
}

extension CaptureNormalExportTests {
    func testCancellationLeavesExistingDestinationAndRawSourceIntact() async throws {
        let root=try root(),source=try await source(root:root),output=root.appendingPathComponent("cancel.mp4")
        let existing=Data("previous export".utf8),frame=try Data(contentsOf:source.frameURL(0));try existing.write(to:output)
        let signal=AsyncStream<Void>.makeStream()
        let task=Task {
            for await _ in signal.stream { break }
            try await CaptureNormalExport.export(source:source,to:output,edits:CaptureNormalEdits(),options:CaptureMovieExport.Options())
        }
        task.cancel();signal.continuation.finish()
        do { try await task.value;XCTFail("Cancelled export was published") } catch { }
        XCTAssertEqual(try Data(contentsOf:output),existing);XCTAssertEqual(try Data(contentsOf:source.frameURL(0)),frame)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:root.path).contains { $0.hasPrefix(".thermo-normal-export-") })
    }
}

extension CaptureNormalExportTests {
    func testPlanarStereoPCMIsStoredWithBothChannelsIntact() async throws {
        let root=try root(),archive=try CaptureFrameArchive(root:root.appendingPathComponent("frames"),header:.init(width:160,height:120,fps:5))
        XCTAssertTrue(try archive.appendVideo(fixtures.frame(),at:time(100)))
        var description=AudioStreamBasicDescription(mSampleRate:48000,mFormatID:kAudioFormatLinearPCM,mFormatFlags:kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked|kAudioFormatFlagIsNonInterleaved,mBytesPerPacket:4,mFramesPerPacket:1,mBytesPerFrame:4,mChannelsPerFrame:2,mBitsPerChannel:32,mReserved:0)
        var format:CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator:kCFAllocatorDefault,asbd:&description,layoutSize:0,layout:nil,magicCookieSize:0,magicCookie:nil,extensions:nil,formatDescriptionOut:&format),noErr)
        let left=(0..<4800).map { Float(sin(Double($0)*2*Double.pi*440/48000))*0.2 }
        let right=(0..<4800).map { Float(cos(Double($0)*2*Double.pi*440/48000))*0.1 }
        let values=left+right
        var block:CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator:kCFAllocatorDefault,memoryBlock:nil,blockLength:values.count*4,blockAllocator:kCFAllocatorDefault,customBlockSource:nil,offsetToData:0,dataLength:values.count*4,flags:0,blockBufferOut:&block),noErr)
        let data=try XCTUnwrap(block)
        values.withUnsafeBytes { _=CMBlockBufferReplaceDataBytes(with:$0.baseAddress!,blockBuffer:data,offsetIntoDestination:0,dataLength:$0.count) }
        var timing=CMSampleTimingInfo(duration:CMTime(value:1,timescale:48000),presentationTimeStamp:time(100),decodeTimeStamp:.invalid),sample:CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator:kCFAllocatorDefault,dataBuffer:data,formatDescription:format!,sampleCount:4800,sampleTimingEntryCount:1,sampleTimingArray:&timing,sampleSizeEntryCount:0,sampleSizeArray:nil,sampleBufferOut:&sample),noErr)
        try archive.appendAudio(try XCTUnwrap(sample));_=try await archive.finish(at:time(100.1))
        let source=try CaptureFrameArchiveSource.load(archive.root),audio=try AVAudioFile(forReading:try XCTUnwrap(source.audioURL),commonFormat:.pcmFormatFloat32,interleaved:false)
        let pcm=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:audio.processingFormat,frameCapacity:4800))
        try audio.read(into:pcm)
        XCTAssertEqual(pcm.frameLength,4800)
        let channels=try XCTUnwrap(pcm.floatChannelData)
        for index in [0,100,1000,4799] {
            XCTAssertEqual(channels[0][index],left[index],accuracy:0.00001)
            XCTAssertEqual(channels[1][index],right[index],accuracy:0.00001)
        }
    }
}

extension CaptureNormalExportTests {
    func testTransparentSourceClearsReusedCanvasAndSurvivesWebPExport() async throws {
        let root=try root(),archive=try CaptureFrameArchive(root:root.appendingPathComponent("frames"),header:.init(width:160,height:120,fps:5))
        XCTAssertTrue(try archive.appendVideo(fixtures.frame(.red),at:time(100)))
        let transparent=try fixtures.frame(.clear)
        CVPixelBufferLockBaseAddress(transparent,[])
        let context=try XCTUnwrap(CGContext(data:CVPixelBufferGetBaseAddress(transparent),width:160,height:120,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(transparent),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue))
        context.clear(CGRect(x:0,y:0,width:160,height:120));context.setFillColor(NSColor.blue.withAlphaComponent(0.5).cgColor);context.fill(CGRect(x:0,y:0,width:20,height:20))
        CVPixelBufferUnlockBaseAddress(transparent,[])
        XCTAssertTrue(try archive.appendVideo(transparent,at:time(101)));_=try await archive.finish(at:time(102))
        let source=try CaptureFrameArchiveSource.load(archive.root)
        var edits=CaptureNormalEdits();edits.showCursor=false
        let renderer=try CaptureNormalRenderer(source:source,edits:edits)
        let reused=try XCTUnwrap(CGContext(data:nil,width:160,height:120,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        try renderer.draw(at:0.2,in:reused);try renderer.draw(at:1.2,in:reused)
        XCTAssertLessThan(try fixtures.color(try XCTUnwrap(reused.makeImage()),x:80,y:10).alphaComponent,0.01)
        var options=CaptureMovieExport.Options();options.format = .webp;options.fps=5;options.maxDimension=160
        let output=root.appendingPathComponent("transparent.webp")
        try await CaptureNormalExport.export(source:source,to:output,edits:edits,options:options)
        let images=try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL,nil)),count=CGImageSourceGetCount(images)
        let last=try XCTUnwrap(CGImageSourceCreateImageAtIndex(images,count-1,nil))
        XCTAssertLessThan(try fixtures.color(last,x:80,y:10).alphaComponent,0.01)
        let patch=try fixtures.color(last,x:10,y:110)
        XCTAssertEqual(patch.alphaComponent,0.5,accuracy:0.02);XCTAssertGreaterThan(patch.blueComponent,0.9)
    }
}

extension CaptureNormalExportTests {
    func testSixteenFPSAnimationTimingMatchesTrimForBothSourceModes() async throws {
        let root=try root(),source=try await source(root:root),movie=root.appendingPathComponent("source.mp4")
        var movieOptions=CaptureMovieExport.Options();movieOptions.fps=5
        var edits=CaptureNormalEdits();edits.showCursor=false
        try await CaptureNormalExport.export(source:source,to:movie,edits:edits,options:movieOptions)
        for ordinary in [true,false] {
            for format in [CaptureMovieFormat.gif,.apng,.webp] {
                var options=CaptureMovieExport.Options();options.format=format;options.fps=16;options.start=0.1;options.end=1.9
                let output=root.appendingPathComponent("timing-\(ordinary)."+format.fileExtension)
                if ordinary { try await CaptureNormalExport.export(source:source,to:output,edits:edits,options:options) }
                else { try await CaptureMovieExport.export(source:movie,to:output,options:options) }
                let images=try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL,nil)),count=CGImageSourceGetCount(images)
                var total=0.0
                for index in 0..<count {
                    let properties=try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(images,index,nil) as? [String:Any])
                    let key=format == .gif ? kCGImagePropertyGIFDictionary as String : format == .apng ? kCGImagePropertyPNGDictionary as String : "{WebP}"
                    let timing=try XCTUnwrap(properties[key] as? [String:Any])
                    total += try XCTUnwrap(timing["UnclampedDelayTime"] as? Double ?? timing["DelayTime"] as? Double)
                }
                XCTAssertEqual(total,1.8,accuracy:0.002,"\(format.rawValue) ordinary=\(ordinary)")
                let first=try XCTUnwrap(CGImageSourceCreateImageAtIndex(images,0,nil)),last=try XCTUnwrap(CGImageSourceCreateImageAtIndex(images,count-1,nil))
                XCTAssertGreaterThan(try fixtures.color(first,x:80,y:60).redComponent,0.7)
                XCTAssertGreaterThan(try fixtures.color(last,x:80,y:60).blueComponent,0.7)
            }
        }
    }
}
