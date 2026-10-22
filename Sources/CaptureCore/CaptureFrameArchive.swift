import AppKit
import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct CapturePointerSample: Codable, Sendable, Equatable {
    /// Normalized bottom-left image coordinates. nil means the pointer is outside the capture region.
    public var x: Double?
    public var y: Double?
    public var buttons: UInt32
    public var scroll: Double
    public init(x:Double? = nil,y:Double? = nil,buttons:UInt32 = 0,scroll:Double = 0) { self.x=x; self.y=y; self.buttons=buttons; self.scroll=scroll }
    var valid:Bool {
        (x == nil && y == nil || x.map { $0.isFinite && (0...1).contains($0) } == true && y.map { $0.isFinite && (0...1).contains($0) } == true) && scroll.isFinite
    }
}

public struct CaptureArchivedFrame: Codable, Sendable {
    public let index:Int
    public let time:Double
}
public struct CaptureArchivedPointer: Codable, Sendable {
    public let time:Double
    public let sample:CapturePointerSample
}
public struct CaptureFrameArchiveHeader: Codable, Sendable {
    public enum Codec:String,Codable,Sendable { case png, jpeg }
    public let version:Int
    public let width:Int
    public let height:Int
    public let fps:Int
    public let codec:Codec
    public let pixelScale:Double
    public init(width:Int,height:Int,fps:Int,codec:Codec = .png,pixelScale:Double = 1) {
        version=1; self.width=width; self.height=height; self.fps=fps; self.codec=codec; self.pixelScale=pixelScale
    }
    var valid:Bool { version == 1 && (2...4096).contains(width) && (2...4096).contains(height) && width%2 == 0 && height%2 == 0 && [5,16,24,30,60].contains(fps) && pixelScale.isFinite && pixelScale > 0 && pixelScale <= 8 }
}

public struct CaptureFrameArchiveSource: Sendable {
    public let root:URL
    public let header:CaptureFrameArchiveHeader
    public let frames:[CaptureArchivedFrame]
    public let pointers:[CaptureArchivedPointer]
    public let duration:Double
    public var audioURL:URL? {
        let url=root.appendingPathComponent("system-audio.caf")
        return (try? Self.regular(url)) == true ? url : nil
    }
    public var microphoneURL:URL? {
        let url=root.appendingPathComponent("microphone.caf")
        return (try? Self.regular(url)) == true ? url : nil
    }
    public var cameraSource:CaptureFrameArchiveSource? {
        get throws {
            let url=root.appendingPathComponent("camera",isDirectory:true)
            return FileManager.default.fileExists(atPath:url.path) ? try Self.load(url) : nil
        }
    }
    public func frameURL(_ index:Int) -> URL { root.appendingPathComponent(String(format:"%08d",index)+(header.codec == .png ? ".png" : ".jpg")) }
    public static func load(_ root:URL) throws -> CaptureFrameArchiveSource {
        let attributes=try root.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
        guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { throw CaptureFailure.invalidImage }
        let info=root.appendingPathComponent("header.json")
        guard try regular(info), (try info.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max) <= 16384 else { throw CaptureFailure.invalidImage }
        let header=try JSONDecoder().decode(CaptureFrameArchiveHeader.self,from:Data(contentsOf:info))
        guard header.valid else { throw CaptureMovieFailure.invalidConfiguration }
        let frames:[CaptureArchivedFrame]=try journal(root.appendingPathComponent("frames.jsonl"))
        guard !frames.isEmpty else { throw CaptureMovieFailure.noFrames }
        var previous = -1.0
        for (index,frame) in frames.enumerated() {
            guard frame.index == index, frame.time.isFinite, frame.time >= 0, frame.time > previous else { throw CaptureMovieFailure.invalidTime }
            let url=root.appendingPathComponent(String(format:"%08d",index)+(header.codec == .png ? ".png" : ".jpg"))
            guard try regular(url) else { throw CaptureFailure.invalidImage }; previous=frame.time
        }
        let rawPointers:[CaptureArchivedPointer]=try journal(root.appendingPathComponent("pointer.jsonl"))
        guard rawPointers.allSatisfy({ $0.time.isFinite && $0.time >= 0 && $0.sample.valid }) else { throw CaptureMovieFailure.invalidTime }
        let pointers=rawPointers.sorted { $0.time < $1.time }
        let minimum=max(frames.last!.time,pointers.last?.time ?? 0)+1/Double(header.fps)
        var duration=minimum
        let end=root.appendingPathComponent("end.json")
        if FileManager.default.fileExists(atPath:end.path) {
            guard try regular(end), (try end.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max) <= 1024 else { throw CaptureMovieFailure.invalidTime }
            let stored=try JSONDecoder().decode([String:Double].self,from:Data(contentsOf:end))
            guard let seconds=stored["duration"], seconds.isFinite, seconds > 0, seconds+0.001 >= frames.last!.time else { throw CaptureMovieFailure.invalidTime }
            duration=seconds
        }
        return CaptureFrameArchiveSource(root:root,header:header,frames:frames,pointers:pointers,duration:duration)
    }
    static func regular(_ url:URL) throws -> Bool {
        let attributes=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
        return attributes.isRegularFile == true && attributes.isSymbolicLink != true
    }
    private static func journal<T:Decodable>(_ url:URL) throws -> [T] {
        guard try regular(url), (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max) <= 128*1024*1024 else { throw CaptureFailure.invalidImage }
        let data=try Data(contentsOf:url,options:.mappedIfSafe), lines=data.split(separator:10,omittingEmptySubsequences:false)
        var records:[T]=[]
        for (i,line) in lines.enumerated() where !line.isEmpty {
            do { records.append(try JSONDecoder().decode(T.self,from:Data(line))) }
            catch { if i == lines.count-1 { break }; throw error }
        }
        return records
    }
}

/// An ordinary recording retains editable source frames, an input journal, and lossless PCM audio.
/// The bounded image queue drops incoming frames rather than retaining unbounded pixel buffers.
public final class CaptureFrameArchive: @unchecked Sendable {
    public let root:URL
    public let header:CaptureFrameArchiveHeader
    private let lock=NSLock(), audioLock=NSLock(), cameraLock=NSLock()
    private let queue=DispatchQueue(label:"dev.thermo.recording.archive",qos:.userInitiated)
    private let context=CIContext(options:[.cacheIntermediates:false])
    private let video:FileHandle, pointer:FileHandle
    private let jpegQuality:Double
    private var timeline=CaptureMovieTimeline()
    private var accepting=true, pending=0, frames=0, dropped=0
    private var lastAccepted = -1.0
    private var lastEncoded = -1.0
    private var error:Error?
    private var lastPointer:CaptureArchivedPointer?
    private var pointerPending=0
    private var audio:CaptureAudioLane?
    private var microphone:CaptureAudioLane?
    private var camera:CaptureFrameArchive?
    public init(root:URL,header:CaptureFrameArchiveHeader,jpegQuality:Double = 0.9,timeOrigin:CMTime? = nil) throws {
        guard header.valid, (0.1...1).contains(jpegQuality) else { throw CaptureMovieFailure.invalidConfiguration }
        self.root=root; self.header=header; self.jpegQuality=jpegQuality
        if let timeOrigin { timeline.start(at:timeOrigin) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        do {
            try JSONEncoder().encode(header).write(to:root.appendingPathComponent("header.json"),options:.atomic)
            let frames=root.appendingPathComponent("frames.jsonl"), pointers=root.appendingPathComponent("pointer.jsonl")
            guard FileManager.default.createFile(atPath:frames.path,contents:nil,attributes:[.posixPermissions:0o600]),
                  FileManager.default.createFile(atPath:pointers.path,contents:nil,attributes:[.posixPermissions:0o600]) else { throw CaptureFailure.exportFailed }
            video=try FileHandle(forWritingTo:frames); pointer=try FileHandle(forWritingTo:pointers)
        } catch { try? FileManager.default.removeItem(at:root); throw error }
    }
    public func pause(at time:CMTime) { lock.lock(); defer { lock.unlock() }; if accepting { timeline.pause(at:time) } }
    public func resume(at time:CMTime) { lock.lock(); defer { lock.unlock() }; if accepting { timeline.resume(at:time) } }
    @discardableResult public func appendVideo(_ buffer:CVPixelBuffer,at time:CMTime) throws -> Bool {
        lock.lock()
        guard accepting, !timeline.paused else { lock.unlock(); return false }
        if let error { lock.unlock(); throw error }
        guard time.isNumeric, CVPixelBufferGetWidth(buffer) == header.width, CVPixelBufferGetHeight(buffer) == header.height else { lock.unlock(); throw CaptureMovieFailure.invalidConfiguration }
        guard pending < 4 else { dropped += 1; lock.unlock(); return false }
        timeline.start(at:time)
        guard let output=timeline.presentationTime(at:time), output.seconds > lastAccepted else { lock.unlock(); return false }
        lastAccepted=output.seconds; pending += 1
        queue.async { [self] in
            defer { lock.lock(); pending -= 1; lock.unlock() }
            do {
                try autoreleasepool {
                    let input=CIImage(cvPixelBuffer:buffer)
                    guard let image=context.createCGImage(input,from:CGRect(x:0,y:0,width:header.width,height:header.height)) else { throw CaptureFailure.invalidImage }
                    lock.lock(); let index=frames; let priorError=error; lock.unlock()
                    if let priorError { throw priorError }
                    let url=root.appendingPathComponent(String(format:"%08d",index)+(header.codec == .png ? ".png" : ".jpg"))
                    let data=NSMutableData()
                    guard let destination=CGImageDestinationCreateWithData(data,header.codec == .png ? UTType.png.identifier as CFString : UTType.jpeg.identifier as CFString,1,nil) else { throw CaptureFailure.exportFailed }
                    CGImageDestinationAddImage(destination,image,[kCGImageDestinationLossyCompressionQuality:jpegQuality] as CFDictionary)
                    guard CGImageDestinationFinalize(destination) else { throw CaptureFailure.exportFailed }
                    try (data as Data).write(to:url,options:.atomic)
                    var record=try JSONEncoder().encode(CaptureArchivedFrame(index:index,time:output.seconds)); record.append(10)
                    try video.write(contentsOf:record)
                    lock.lock(); frames += 1; lastEncoded=output.seconds; lock.unlock()
                }
            } catch { lock.lock(); if self.error == nil { self.error=error }; lock.unlock() }
        }
        lock.unlock();return true
    }
    public func recordPointer(_ sample:CapturePointerSample,at time:CMTime) {
        guard sample.valid else { return }
        lock.lock()
        guard accepting, !timeline.paused, let output=timeline.presentationTime(at:time), pointerPending < 2048 else { lock.unlock(); return }
        if let lastPointer, lastPointer.sample == sample, output.seconds-lastPointer.time < 1 { lock.unlock(); return }
        let record=CaptureArchivedPointer(time:output.seconds,sample:sample)
        lastPointer=record; pointerPending += 1
        queue.async { [self] in
            defer { lock.lock(); pointerPending -= 1; lock.unlock() }
            do { var data=try JSONEncoder().encode(record); data.append(10); try pointer.write(contentsOf:data) }
            catch { lock.lock(); if self.error == nil { self.error=error }; lock.unlock() }
        }
        lock.unlock()
    }
    public func appendAudio(_ sample:CMSampleBuffer) throws { try appendAudio(sample,at:CMSampleBufferGetPresentationTimeStamp(sample),microphone:false) }
    public func appendMicrophone(_ sample:CMSampleBuffer,at time:CMTime) throws { try appendAudio(sample,at:time,microphone:true) }
    private func appendAudio(_ sample:CMSampleBuffer,at time:CMTime,microphone isMicrophone:Bool) throws {
        audioLock.lock();defer { audioLock.unlock() }
        lock.lock()
        guard accepting,!timeline.paused,let output=timeline.presentationTime(at:time) else { lock.unlock();return }
        lock.unlock()
        if isMicrophone {
            if microphone == nil { microphone=CaptureAudioLane(url:root.appendingPathComponent("microphone.caf")) }
            try microphone?.append(sample,at:output.seconds)
        } else {
            if audio == nil { audio=CaptureAudioLane(url:root.appendingPathComponent("system-audio.caf")) }
            try audio?.append(sample,at:output.seconds)
        }
    }
    @discardableResult public func appendCamera(_ buffer:CVPixelBuffer,at time:CMTime) throws -> Bool {
        cameraLock.lock();defer { cameraLock.unlock() }
        lock.lock()
        guard accepting,!timeline.paused,let output=timeline.presentationTime(at:time) else { lock.unlock();return false }
        lock.unlock()
        if camera == nil {
            camera=try CaptureFrameArchive(root:root.appendingPathComponent("camera",isDirectory:true),header:.init(width:CVPixelBufferGetWidth(buffer),height:CVPixelBufferGetHeight(buffer),fps:header.fps == 60 ? 30 : header.fps,codec:header.codec),jpegQuality:jpegQuality,timeOrigin:.zero)
        }
        return try camera?.appendVideo(buffer,at:output) ?? false
    }
    private func cameraSnapshot() -> CaptureFrameArchive? { cameraLock.lock();defer { cameraLock.unlock() };return camera }
    public func statistics(at time:CMTime) -> CaptureMovieWriter.Statistics {
        lock.lock();let count=frames,drops=dropped,seconds=timeline.presentationTime(at:time)?.seconds ?? 0;lock.unlock()
        let cameraDrops=cameraSnapshot()?.statistics(at:CMTime(seconds:seconds,preferredTimescale:60000)).droppedFrames ?? 0
        return .init(frames:count,droppedFrames:drops+cameraDrops,seconds:seconds)
    }
    private func beginFinish(at time:CMTime) throws -> Double {
        lock.lock(); defer { lock.unlock() }
        guard accepting else { throw CaptureMovieFailure.notRecording }; accepting=false
        return timeline.presentationTime(at:time)?.seconds ?? 0
    }
    public func finish(at time:CMTime) async throws -> URL {
        let duration=try beginFinish(at:time)
        if let camera=cameraSnapshot() { _=try await camera.finish(at:CMTime(seconds:duration,preferredTimescale:60000)) }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    audioLock.lock();audio?.close();microphone?.close();audio=nil;microphone=nil;audioLock.unlock()
                    lock.lock(); let storedError=error; let count=frames; let end=max(duration,lastEncoded+1/60000); lock.unlock()
                    if let storedError { throw storedError }; guard count > 0 else { throw CaptureMovieFailure.noFrames }
                    try video.synchronize(); try pointer.synchronize()
                    try JSONEncoder().encode(["duration":end]).write(to:root.appendingPathComponent("end.json"),options:.atomic)
                    continuation.resume(returning:root)
                } catch { continuation.resume(throwing:error) }
            }
        }
    }
    public func cancel() { lock.lock(); accepting=false; lock.unlock() }
    public func cancelAndWait() async {
        cancel()
        if let camera=cameraSnapshot() { await camera.cancelAndWait() }
        await withCheckedContinuation { (continuation:CheckedContinuation<Void,Never>) in
            queue.async { [self] in
                audioLock.lock();audio?.close();microphone?.close();audio=nil;microphone=nil;audioLock.unlock()
                try? video.synchronize();try? pointer.synchronize();continuation.resume()
            }
        }
    }
    deinit { try? video.close(); try? pointer.close() }
}
