import AppKit
import AVFoundation
import XCTest
@testable import CaptureCore

final class CaptureAVLayersTests:XCTestCase {
    private let fixtures=CaptureArchiveFixtures()
    private func time(_ value:Double) -> CMTime { CMTime(seconds:value,preferredTimescale:60000) }
    private func root() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-av-layer-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        addTeardownBlock { try FileManager.default.removeItem(at:root) };return root
    }
    private func cameraFrame() throws -> CVPixelBuffer {
        let buffer=try fixtures.frame(.green)
        CVPixelBufferLockBaseAddress(buffer,[]);defer { CVPixelBufferUnlockBaseAddress(buffer,[]) }
        let ctx=try XCTUnwrap(CGContext(data:CVPixelBufferGetBaseAddress(buffer),width:160,height:120,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(buffer),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue))
        ctx.setFillColor(NSColor.red.cgColor);ctx.fill(CGRect(x:0,y:0,width:80,height:120));return buffer
    }
    func testCameraIsSynchronizedAndCanHideMoveMirrorAndCrop() async throws {
        let root=try root(),archive=try CaptureFrameArchive(root:root.appendingPathComponent("frames"),header:.init(width:160,height:120,fps:5))
        XCTAssertTrue(try archive.appendVideo(fixtures.frame(),at:time(100)))
        XCTAssertTrue(try archive.appendCamera(cameraFrame(),at:time(100.5)))
        archive.pause(at:time(101));XCTAssertFalse(try archive.appendCamera(cameraFrame(),at:time(103)))
        archive.resume(at:time(106));XCTAssertTrue(try archive.appendCamera(cameraFrame(),at:time(107)))
        _=try await archive.finish(at:time(108));let source=try CaptureFrameArchiveSource.load(archive.root)
        let camera=try XCTUnwrap(try source.cameraSource)
        XCTAssertEqual(camera.frames.map(\.time),[0.5,2]);XCTAssertEqual(source.duration,3,accuracy:0.001)
        var edits=CaptureNormalEdits(),settings=CaptureCameraEdits();edits.showCursor=false;settings.margin=0;settings.mirrored=false;edits.camera=settings
        let plain=try CaptureNormalRenderer(source:source,edits:edits)
        XCTAssertGreaterThan(try fixtures.color(plain.image(at:0.2),x:130,y:105).blueComponent,0.9)
        XCTAssertGreaterThan(try fixtures.color(plain.image(at:0.8),x:130,y:105).redComponent,0.9)
        settings.mirrored=true;edits.camera=settings
        XCTAssertGreaterThan(try fixtures.color(CaptureNormalRenderer(source:source,edits:edits).image(at:0.8),x:130,y:105).greenComponent,0.9)
        settings.corner = .topLeft;settings.mirrored=false;edits.camera=settings
        XCTAssertGreaterThan(try fixtures.color(CaptureNormalRenderer(source:source,edits:edits).image(at:0.8),x:10,y:15).redComponent,0.9)
        edits.crop=CGRect(x:0,y:0,width:0.5,height:1);settings.corner = .bottomRight;edits.camera=settings
        let cropped=try CaptureNormalRenderer(source:source,edits:edits).image(at:0.8)
        XCTAssertEqual(cropped.width,80);XCTAssertGreaterThan(try fixtures.color(cropped,x:65,y:110).redComponent,0.9)
        settings.enabled=false;edits.camera=settings
        XCTAssertGreaterThan(try fixtures.color(CaptureNormalRenderer(source:source,edits:edits).image(at:0.8),x:65,y:110).blueComponent,0.9)
    }
    private func audio(at seconds:Double,rate:Double = 48000,channels:Int = 2,frequency:Double = 440,amplitude:Double = 0.2) throws -> CMSampleBuffer {
        let count=Int(rate/10)
        var description=AudioStreamBasicDescription(mSampleRate:rate,mFormatID:kAudioFormatLinearPCM,mFormatFlags:kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked,mBytesPerPacket:UInt32(channels*4),mFramesPerPacket:1,mBytesPerFrame:UInt32(channels*4),mChannelsPerFrame:UInt32(channels),mBitsPerChannel:32,mReserved:0)
        var format:CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator:kCFAllocatorDefault,asbd:&description,layoutSize:0,layout:nil,magicCookieSize:0,magicCookie:nil,extensions:nil,formatDescriptionOut:&format),noErr)
        let values=(0..<count).flatMap { i in Array(repeating:Float(sin(Double(i)*2*Double.pi*frequency/rate)*amplitude),count:channels) }
        var block:CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator:kCFAllocatorDefault,memoryBlock:nil,blockLength:values.count*4,blockAllocator:kCFAllocatorDefault,customBlockSource:nil,offsetToData:0,dataLength:values.count*4,flags:0,blockBufferOut:&block),noErr)
        let data=try XCTUnwrap(block)
        values.withUnsafeBytes { _=CMBlockBufferReplaceDataBytes(with:$0.baseAddress!,blockBuffer:data,offsetIntoDestination:0,dataLength:$0.count) }
        var timing=CMSampleTimingInfo(duration:CMTime(value:1,timescale:Int32(rate)),presentationTimeStamp:time(seconds),decodeTimeStamp:.invalid),sample:CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator:kCFAllocatorDefault,dataBuffer:data,formatDescription:format!,sampleCount:count,sampleTimingEntryCount:1,sampleTimingArray:&timing,sampleSizeEntryCount:0,sampleSizeArray:nil,sampleBufferOut:&sample),noErr)
        return try XCTUnwrap(sample)
    }
    func testMonoMicrophoneIsResampledSeparatelyFromSystemAudio() async throws {
        let root=try root(),archive=try CaptureFrameArchive(root:root.appendingPathComponent("frames"),header:.init(width:160,height:120,fps:5))
        XCTAssertTrue(try archive.appendVideo(fixtures.frame(),at:time(100)))
        for index in 0..<20 {
            try archive.appendAudio(audio(at:100+Double(index)/10))
            try archive.appendMicrophone(audio(at:100+Double(index)/10,rate:44100,channels:1,frequency:880),at:time(100+Double(index)/10))
        }
        _=try await archive.finish(at:time(102));let source=try CaptureFrameArchiveSource.load(archive.root)
        let system=try AVAudioFile(forReading:try XCTUnwrap(source.audioURL)),mic=try AVAudioFile(forReading:try XCTUnwrap(source.microphoneURL))
        XCTAssertEqual(system.length,96000);XCTAssertEqual(mic.length,96000)
        XCTAssertEqual(mic.processingFormat.sampleRate,48000);XCTAssertEqual(mic.processingFormat.channelCount,2)
        let pcm=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:mic.processingFormat,frameCapacity:4800));try mic.read(into:pcm)
        let data=try XCTUnwrap(pcm.floatChannelData)
        XCTAssertEqual(data[0][1000],data[1][1000],accuracy:0.0001)
        XCTAssertGreaterThan((0..<Int(pcm.frameLength)).reduce(0.0) { $0+Double(data[0][$1]*data[0][$1]) },1)
    }
    private func decoded(_ url:URL) async throws -> (Double,Int) {
        let asset=AVURLAsset(url:url),tracks=try await asset.loadTracks(withMediaType:.audio)
        guard let track=tracks.first else { return (0,0) }
        let reader=try AVAssetReader(asset:asset),output=AVAssetReaderTrackOutput(track:track,outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVLinearPCMIsFloatKey:true,AVLinearPCMBitDepthKey:32,AVLinearPCMIsNonInterleaved:false])
        guard reader.canAdd(output) else { throw CaptureFailure.exportFailed };reader.add(output);XCTAssertTrue(reader.startReading())
        var energy=0.0,count=0
        while let sample=output.copyNextSampleBuffer(),let data=CMSampleBufferGetDataBuffer(sample) {
            var values=[Float](repeating:0,count:CMBlockBufferGetDataLength(data)/4)
            values.withUnsafeMutableBytes { _=CMBlockBufferCopyDataBytes(data,atOffset:0,dataLength:$0.count,destination:$0.baseAddress!) }
            energy += values.reduce(0) { $0+Double($1*$1) };count += values.count
        }
        XCTAssertEqual(reader.status,.completed);return (sqrt(energy/Double(max(1,count))),count)
    }
    func testIndependentGainsMixAndMuteWithoutChangingRawAudio() async throws {
        let root=try root(),archive=try CaptureFrameArchive(root:root.appendingPathComponent("frames"),header:.init(width:160,height:120,fps:5))
        XCTAssertTrue(try archive.appendVideo(fixtures.frame(),at:time(100)))
        for index in 0..<20 {
            try archive.appendAudio(audio(at:100+Double(index)/10))
            try archive.appendMicrophone(audio(at:100+Double(index)/10,frequency:880),at:time(100+Double(index)/10))
        }
        _=try await archive.finish(at:time(102));let source=try CaptureFrameArchiveSource.load(archive.root)
        let before=try Data(contentsOf:try XCTUnwrap(source.microphoneURL))
        var edits=CaptureNormalEdits(),options=CaptureMovieExport.Options();options.fps=5;options.start=0.2;options.end=1.8
        edits.systemVolume=0;edits.microphoneVolume=0.25
        let quiet=root.appendingPathComponent("quiet.mp4")
        try await CaptureNormalExport.export(source:source,to:quiet,edits:edits,options:options)
        let reduced=try await decoded(quiet)
        XCTAssertGreaterThan(reduced.0,0.015);XCTAssertLessThan(reduced.0,0.06);XCTAssertEqual(Double(reduced.1)/2/48000,1.6,accuracy:0.1)
        edits.systemVolume=0.5;edits.microphoneVolume=0.5
        let mixed=root.appendingPathComponent("mixed.mp4")
        try await CaptureNormalExport.export(source:source,to:mixed,edits:edits,options:options)
        let sum=try await decoded(mixed)
        XCTAssertGreaterThan(sum.0,reduced.0*2)
        edits.systemVolume=0;edits.microphoneVolume=0
        let muted=root.appendingPathComponent("muted.mp4")
        try await CaptureNormalExport.export(source:source,to:muted,edits:edits,options:options)
        let silent=try await AVURLAsset(url:muted).loadTracks(withMediaType:.audio);XCTAssertTrue(silent.isEmpty)
        XCTAssertEqual(try Data(contentsOf:try XCTUnwrap(source.microphoneURL)),before)
    }
    func testOldEditFilesKeepDefaultAVLayerSettings() throws {
        let root=try root(),edits=CaptureNormalEdits();try edits.save(to:root)
        var dictionary=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("edits.json"))) as? [String:Any])
        dictionary.removeValue(forKey:"camera");dictionary.removeValue(forKey:"microphoneVolume")
        try JSONSerialization.data(withJSONObject:dictionary).write(to:root.appendingPathComponent("edits.json"))
        let loaded=try CaptureNormalEdits.load(from:root)
        XCTAssertNil(loaded.camera);XCTAssertEqual(loaded.microphoneVolume ?? 1,1)
        var invalid=loaded;invalid.microphoneVolume = .nan;XCTAssertFalse(invalid.valid)
        var camera=CaptureCameraEdits();camera.width=2;invalid=loaded;invalid.camera=camera;XCTAssertFalse(invalid.valid)
    }
}

extension CaptureAVLayersTests {
    func testCameraCircleAndAllExportFormatsUseIndependentFrames() async throws {
        let root=try root(),archive=try CaptureFrameArchive(root:root.appendingPathComponent("frames"),header:.init(width:160,height:120,fps:5))
        XCTAssertTrue(try archive.appendVideo(fixtures.frame(),at:time(100)));XCTAssertTrue(try archive.appendCamera(cameraFrame(),at:time(100)))
        _=try await archive.finish(at:time(102));let source=try CaptureFrameArchiveSource.load(archive.root),camera=try XCTUnwrap(try source.cameraSource)
        let original=try Data(contentsOf:camera.frameURL(0))
        var edits=CaptureNormalEdits(),settings=CaptureCameraEdits();edits.showCursor=false;settings.margin=0;settings.shape = .circle;settings.mirrored=false;edits.camera=settings
        let preview=try CaptureNormalRenderer(source:source,edits:edits).image(at:0.5)
        XCTAssertGreaterThan(try fixtures.color(preview,x:121,y:119).blueComponent,0.9)
        XCTAssertGreaterThan(try fixtures.color(preview,x:130,y:100).redComponent,0.9)
        for format in CaptureMovieFormat.allCases {
            var options=CaptureMovieExport.Options();options.format=format;options.fps=5;options.start=0.2;options.end=1.8;options.speed=2;options.maxDimension=160
            let output=root.appendingPathComponent("camera."+format.fileExtension)
            try await CaptureNormalExport.export(source:source,to:output,edits:edits,options:options)
            let image:CGImage
            if format == .mp4 {
                let asset=AVURLAsset(url:output),duration=try await asset.load(.duration)
                XCTAssertEqual(duration.seconds,0.8,accuracy:0.03)
                image=try AVAssetImageGenerator(asset:asset).copyCGImage(at:time(0.2),actualTime:nil)
            } else {
                let images=try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL,nil));image=try XCTUnwrap(CGImageSourceCreateImageAtIndex(images,0,nil))
            }
            XCTAssertGreaterThan(try fixtures.color(image,x:130,y:100).redComponent,0.7,format.rawValue)
            XCTAssertGreaterThan(try fixtures.color(image,x:121,y:119).blueComponent,0.7,format.rawValue)
        }
        XCTAssertEqual(try Data(contentsOf:camera.frameURL(0)),original)
    }
    func testCameraSymlinkIsRejectedAndCanBeExplicitlyHiddenForRecovery() async throws {
        let root=try root(),archive=try CaptureFrameArchive(root:root.appendingPathComponent("frames"),header:.init(width:160,height:120,fps:5))
        XCTAssertTrue(try archive.appendVideo(fixtures.frame(),at:time(100)));_=try await archive.finish(at:time(102))
        let outside=root.appendingPathComponent("outside",isDirectory:true);try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:false)
        try FileManager.default.createSymbolicLink(at:archive.root.appendingPathComponent("camera"),withDestinationURL:outside)
        let source=try CaptureFrameArchiveSource.load(archive.root)
        XCTAssertThrowsError(try CaptureNormalRenderer(source:source,edits:CaptureNormalEdits()))
        var edits=CaptureNormalEdits(),camera=CaptureCameraEdits();camera.enabled=false;edits.camera=camera
        XCTAssertNoThrow(try CaptureNormalRenderer(source:source,edits:edits).image(at:1))
    }
}

extension CaptureAVLayersTests {
    func testMicrophonePauseExcludesSamplesAndSupports48kMono() async throws {
        let root=try root(),archive=try CaptureFrameArchive(root:root.appendingPathComponent("frames"),header:.init(width:160,height:120,fps:5))
        XCTAssertTrue(try archive.appendVideo(fixtures.frame(),at:time(100)))
        try archive.appendMicrophone(audio(at:100,channels:1),at:time(100))
        archive.pause(at:time(100.1))
        try archive.appendMicrophone(audio(at:101,channels:1),at:time(101))
        archive.resume(at:time(105.1))
        for packet in 0..<10 { try archive.appendMicrophone(audio(at:105.1+Double(packet)/10,channels:1),at:time(105.1+Double(packet)/10)) }
        _=try await archive.finish(at:time(106.1));let source=try CaptureFrameArchiveSource.load(archive.root)
        let mic=try AVAudioFile(forReading:try XCTUnwrap(source.microphoneURL))
        XCTAssertEqual(mic.length,52800);XCTAssertEqual(source.duration,1.1,accuracy:0.0001)
    }
}
