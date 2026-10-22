import AVFoundation
import AppKit
import XCTest
@testable import CaptureCore

final class CaptureMovieWriterTests: XCTestCase {
    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 60_000) }
    private func buffer(_ red: UInt8 = 200) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault,160,120,kCVPixelFormatType_32BGRA,[kCVPixelBufferCGImageCompatibilityKey:true,kCVPixelBufferCGBitmapContextCompatibilityKey:true] as CFDictionary,&buffer),kCVReturnSuccess)
        let result = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(result,[]); defer { CVPixelBufferUnlockBaseAddress(result,[]) }
        let base = CVPixelBufferGetBaseAddress(result)!.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(result)
        for y in 0..<120 { for x in 0..<160 {
            let i = y*stride+x*4; base[i] = 20; base[i+1] = 30; base[i+2] = red; base[i+3] = 255
        } }
        return result
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-movie-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: url,withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }; return url
    }
    func testTimelineExcludesPausesAndStartsOnFirstFrame() {
        var timeline = CaptureMovieTimeline()
        timeline.pause(at: time(1)); timeline.resume(at: time(4)); timeline.start(at: time(10))
        XCTAssertEqual(timeline.presentationTime(at: time(11))!.seconds,1,accuracy:0.0001)
        timeline.pause(at: time(12))
        XCTAssertEqual(timeline.presentationTime(at: time(15))!.seconds,2,accuracy:0.0001)
        timeline.resume(at: time(17))
        XCTAssertEqual(timeline.presentationTime(at: time(18))!.seconds,3,accuracy:0.0001)
        XCTAssertNil(timeline.presentationTime(at: time(9)))
    }
    func testEncodedMovieHasPlayableFramesAndStaticTailDuration() async throws {
        let url = try directory().appendingPathComponent("movie.mp4")
        let writer = try CaptureMovieWriter(url:url,width:160,height:120)
        let frame = try buffer()
        XCTAssertTrue(try writer.appendVideo(frame,at:time(100)))
        _ = try await writer.finish(at:time(102))
        let asset = AVURLAsset(url:url)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds,2,accuracy:0.05)
        let tracks = try await asset.loadTracks(withMediaType:.video)
        XCTAssertEqual(tracks.count,1)
        let generator = AVAssetImageGenerator(asset:asset)
        let image = try generator.copyCGImage(at:time(1),actualTime:nil)
        XCTAssertEqual(image.width,160); XCTAssertEqual(image.height,120)
        let rep = NSBitmapImageRep(cgImage:image), color = try XCTUnwrap(rep.colorAt(x:80,y:60)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(color.redComponent,0.6); XCTAssertLessThan(color.greenComponent,0.3)
    }
    func testPausedFramesAreDiscardedAndPauseIsAbsentFromMovie() async throws {
        let url = try directory().appendingPathComponent("paused.mp4"), frame = try buffer()
        let writer = try CaptureMovieWriter(url:url,width:160,height:120)
        XCTAssertTrue(try writer.appendVideo(frame,at:time(100)))
        writer.pause(at:time(101)); XCTAssertFalse(try writer.appendVideo(frame,at:time(104)))
        writer.resume(at:time(106)); XCTAssertTrue(try writer.appendVideo(frame,at:time(107)))
        _ = try await writer.finish(at:time(108))
        let duration = try await AVURLAsset(url:url).load(.duration)
        XCTAssertEqual(duration.seconds,3,accuracy:0.05)
        XCTAssertEqual(writer.statistics(at:time(108)).frames,2)
    }
    func testStoppingWhilePausedDoesNotIncludeWaitingTime() async throws {
        let url = try directory().appendingPathComponent("paused-stop.mp4"), writer = try CaptureMovieWriter(url:url,width:160,height:120)
        XCTAssertTrue(try writer.appendVideo(buffer(),at:time(100)))
        writer.pause(at:time(101)); _ = try await writer.finish(at:time(111))
        let duration = try await AVURLAsset(url:url).load(.duration)
        XCTAssertEqual(duration.seconds,1,accuracy:0.05)
    }
    func testFinishWithNoFramesFailsAndCancelRejectsMoreFrames() async throws {
        let url = try directory().appendingPathComponent("empty.mp4"), writer = try CaptureMovieWriter(url:url,width:160,height:120)
        do { _ = try await writer.finish(at:time(10)); XCTFail("Empty movie accepted") } catch { }
        XCTAssertFalse(try writer.appendVideo(buffer(),at:time(11)))
    }
    func testInvalidSizesAndRatesAreRejectedBeforeCreatingOutput() throws {
        let url = try directory().appendingPathComponent("invalid.mp4")
        XCTAssertThrowsError(try CaptureMovieWriter(url:url,width:159,height:120))
        XCTAssertThrowsError(try CaptureMovieWriter(url:url,width:160,height:120,fps:120))
        XCTAssertFalse(FileManager.default.fileExists(atPath:url.path))
    }
}

extension CaptureMovieWriterTests {
    func testSystemAudioIsEncodedAndSurvivesMP4Export() async throws {
        let folder = try directory(), source = folder.appendingPathComponent("audio.mp4")
        let writer = try CaptureMovieWriter(url:source,width:160,height:120,systemAudio:true)
        XCTAssertTrue(try writer.appendVideo(buffer(),at:time(100)))
        var description = AudioStreamBasicDescription(mSampleRate:48000,mFormatID:kAudioFormatLinearPCM,
            mFormatFlags:kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked,mBytesPerPacket:8,mFramesPerPacket:1,mBytesPerFrame:8,mChannelsPerFrame:2,mBitsPerChannel:32,mReserved:0)
        var format:CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator:kCFAllocatorDefault,asbd:&description,layoutSize:0,layout:nil,magicCookieSize:0,magicCookie:nil,extensions:nil,formatDescriptionOut:&format),noErr)
        let values = (0..<4800).flatMap { i -> [Float] in let value = Float(sin(Double(i)*2*Double.pi*440/48000))*0.2; return [value,value] }
        for packet in 0..<20 {
            var block:CMBlockBuffer?
            XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator:kCFAllocatorDefault,memoryBlock:nil,blockLength:values.count*4,blockAllocator:kCFAllocatorDefault,customBlockSource:nil,offsetToData:0,dataLength:values.count*4,flags:0,blockBufferOut:&block),noErr)
            let data = try XCTUnwrap(block)
            values.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with:$0.baseAddress!,blockBuffer:data,offsetIntoDestination:0,dataLength:$0.count) }
            var timing = CMSampleTimingInfo(duration:CMTime(value:1,timescale:48000),presentationTimeStamp:time(100+Double(packet)*0.1),decodeTimeStamp:.invalid)
            var sample:CMSampleBuffer?
            XCTAssertEqual(CMSampleBufferCreateReady(allocator:kCFAllocatorDefault,dataBuffer:data,formatDescription:format!,sampleCount:4800,sampleTimingEntryCount:1,sampleTimingArray:&timing,sampleSizeEntryCount:0,sampleSizeArray:nil,sampleBufferOut:&sample),noErr)
            try writer.appendAudio(try XCTUnwrap(sample)); try await Task.sleep(nanoseconds:1_000_000)
        }
        _ = try await writer.finish(at:time(102))
        let sourceAudio = try await AVURLAsset(url:source).loadTracks(withMediaType:.audio)
        XCTAssertEqual(sourceAudio.count,1)
        let destination = folder.appendingPathComponent("audio-trim.mp4")
        var options = CaptureMovieExport.Options(); options.start = 0.2; options.end = 1.8
        try await CaptureMovieExport.export(source:source,to:destination,options:options)
        let exportedAsset = AVURLAsset(url:destination)
        let audio = try await exportedAsset.loadTracks(withMediaType:.audio)
        XCTAssertEqual(audio.count,1)
        let reader = try AVAssetReader(asset:exportedAsset)
        let pcm = AVAssetReaderTrackOutput(track:audio[0],outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey:true,AVLinearPCMBitDepthKey:32,AVLinearPCMIsNonInterleaved:false])
        guard reader.canAdd(pcm) else { XCTFail("Exported audio could not be decoded"); return }
        reader.add(pcm); XCTAssertTrue(reader.startReading())
        var energy = 0.0, count = 0
        while let sample = pcm.copyNextSampleBuffer() {
            guard let data = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(data)
            var values = [Float](repeating:0,count:length/4)
            XCTAssertEqual(values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(data,atOffset:0,dataLength:length,destination:$0.baseAddress!) },noErr)
            for value in values { energy += Double(value*value) }; count += values.count
        }
        XCTAssertEqual(reader.status,.completed)
        XCTAssertGreaterThan(count,48000)
        XCTAssertGreaterThan(sqrt(energy/Double(max(1,count))),0.05)
        XCTAssertEqual(Double(count)/2/48000,1.6,accuracy:0.1)
        let duration = try await AVURLAsset(url:destination).load(.duration)
        XCTAssertEqual(duration.seconds,1.6,accuracy:0.08)
    }
}
