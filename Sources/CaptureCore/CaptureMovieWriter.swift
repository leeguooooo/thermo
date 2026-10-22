import AVFoundation
import CoreVideo
import Foundation

public enum CaptureMovieFailure: LocalizedError {
    case invalidConfiguration, notRecording, noFrames, encoding(String), invalidTime
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "The recording size or frame rate is invalid."
        case .notRecording: return "The recording is no longer accepting frames."
        case .noFrames: return "No screen frames were recorded."
        case .encoding(let message): return "Video encoding failed: " + message
        case .invalidTime: return "The recording timestamp is invalid."
        }
    }
}

/// Uses one monotonic source clock for video, audio, pause and stop. Pauses never enter output time.
public struct CaptureMovieTimeline {
    private var origin: CMTime?
    private var pauseBegan: CMTime?
    private var excluded = CMTime.zero
    public init() {}
    public var paused: Bool { pauseBegan != nil }
    public mutating func pause(at time: CMTime) {
        guard pauseBegan == nil, time.isNumeric else { return }; pauseBegan = time
    }
    public mutating func resume(at time: CMTime) {
        guard let start = pauseBegan, time.isNumeric, time >= start else { return }
        if let origin { excluded = excluded + time - max(start, origin) }
        pauseBegan = nil
    }
    public mutating func start(at time: CMTime) {
        guard origin == nil, time.isNumeric, !paused else { return }; origin = time
    }
    public func presentationTime(at time: CMTime) -> CMTime? {
        guard let origin, time.isNumeric, time >= origin else { return nil }
        let end = min(time, pauseBegan ?? time)
        let output = end-origin-excluded
        return output >= .zero ? output : nil
    }
}

/// All mutable writer state is protected by lock. ScreenCaptureKit callbacks never wait for an encoder.
public final class CaptureMovieWriter: @unchecked Sendable {
    public struct Statistics: Sendable {
        public let frames: Int
        public let droppedFrames: Int
        public let seconds: Double
    }
    public let url: URL
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput?
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let lock = NSLock()
    private var timeline = CaptureMovieTimeline()
    private enum Phase { case accepting, finishing, finished, cancelled }
    private var phase = Phase.accepting
    private var began = false
    private var lastVideo: CMTime?
    private var lastAudio: CMTime?
    private var lastBuffer: CVPixelBuffer?
    private var frames = 0, dropped = 0
    private var storedError: Error?
    public init(url: URL, width: Int, height: Int, fps: Int = 30, bitRate: Int = 8_000_000, systemAudio: Bool = false) throws {
        guard width >= 2, height >= 2, width <= 4096, height <= 4096, width%2 == 0, height%2 == 0,
              [5,16,24,30,60].contains(fps), (100_000...100_000_000).contains(bitRate) else { throw CaptureMovieFailure.invalidConfiguration }
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        // Periodic fragments also keep long captures from requiring an unbounded in-memory index.
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitRate, AVVideoExpectedSourceFrameRateKey: fps,
                                             AVVideoMaxKeyFrameIntervalKey: fps*2, AVVideoAllowFrameReorderingKey: false]])
        video.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        guard writer.canAdd(video) else { throw CaptureMovieFailure.invalidConfiguration }; writer.add(video)
        if systemAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw CaptureMovieFailure.invalidConfiguration }; writer.add(input); audio = input
        } else { audio = nil }
    }
    public func pause(at time: CMTime) { lock.lock(); defer { lock.unlock() }; if phase == .accepting { timeline.pause(at: time) } }
    public func resume(at time: CMTime) { lock.lock(); defer { lock.unlock() }; if phase == .accepting { timeline.resume(at: time) } }
    @discardableResult public func appendVideo(_ buffer: CVPixelBuffer, at time: CMTime) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard phase == .accepting else { return false }
        guard time.isNumeric else { throw CaptureMovieFailure.invalidTime }
        guard !timeline.paused else { return false }
        if let storedError { throw storedError }
        timeline.start(at: time)
        guard let output = timeline.presentationTime(at: time), lastVideo.map({ output > $0 }) ?? true else { return false }
        if !began {
            guard writer.startWriting() else { throw writer.error ?? CaptureMovieFailure.encoding("Unable to start writer") }
            writer.startSession(atSourceTime: .zero); began = true
        }
        guard video.isReadyForMoreMediaData else { dropped += 1; return false }
        guard adaptor.append(buffer, withPresentationTime: output) else {
            storedError = writer.error ?? CaptureMovieFailure.encoding("Unable to append video"); throw storedError!
        }
        lastVideo = output; lastBuffer = buffer; frames += 1; return true
    }
    public func appendAudio(_ sample: CMSampleBuffer) throws {
        lock.lock(); defer { lock.unlock() }
        guard phase == .accepting, began, !timeline.paused, let audio, sample.isValid else { return }
        let source = CMSampleBufferGetPresentationTimeStamp(sample)
        guard let output = timeline.presentationTime(at: source), lastAudio.map({ output > $0 }) ?? true else { return }
        guard audio.isReadyForMoreMediaData else { return }
        var count = 0
        var status = CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard status == noErr, count > 0 else { throw CaptureMovieFailure.invalidTime }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(duration: .invalid,presentationTimeStamp: .invalid,decodeTimeStamp: .invalid),count: count)
        status = timings.withUnsafeMutableBufferPointer { CMSampleBufferGetSampleTimingInfoArray(sample,entryCount: count,arrayToFill: $0.baseAddress,entriesNeededOut: &count) }
        guard status == noErr else { throw CaptureMovieFailure.invalidTime }
        let offset = source-output
        for i in timings.indices {
            if timings[i].presentationTimeStamp.isNumeric { timings[i].presentationTimeStamp = timings[i].presentationTimeStamp-offset }
            if timings[i].decodeTimeStamp.isNumeric { timings[i].decodeTimeStamp = timings[i].decodeTimeStamp-offset }
        }
        var adjusted: CMSampleBuffer?
        status = timings.withUnsafeBufferPointer { CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,sampleBuffer: sample,sampleTimingEntryCount: count,sampleTimingArray: $0.baseAddress!,sampleBufferOut: &adjusted) }
        guard status == noErr, let adjusted else { throw CaptureMovieFailure.invalidTime }
        guard audio.append(adjusted) else { storedError = writer.error ?? CaptureMovieFailure.encoding("Unable to append audio"); throw storedError! }
        lastAudio = output
    }
    public func statistics(at time: CMTime) -> Statistics {
        lock.lock(); defer { lock.unlock() }
        return Statistics(frames: frames, droppedFrames: dropped, seconds: timeline.presentationTime(at: time)?.seconds ?? 0)
    }
    private func beginFinish(at time: CMTime) throws -> (CMTime, CVPixelBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard phase == .accepting else { throw CaptureMovieFailure.notRecording }
        guard began, frames > 0, let buffer = lastBuffer, let last = lastVideo else { throw CaptureMovieFailure.noFrames }
        if let storedError { throw storedError }
        phase = .finishing
        return (max(last + CMTime(value: 1,timescale: 600), timeline.presentationTime(at: time) ?? last), buffer)
    }
    public func finish(at time: CMTime) async throws -> URL {
        do {
            let (end, buffer) = try beginFinish(at: time)
            // Duplicate the last visible frame at stop time so a static desktop keeps its real duration.
            for _ in 0..<200 {
                if video.isReadyForMoreMediaData { break }
                if writer.status == .failed { throw writer.error ?? CaptureMovieFailure.encoding("Writer failed") }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            guard video.isReadyForMoreMediaData, adaptor.append(buffer,withPresentationTime: end) else { throw writer.error ?? CaptureMovieFailure.encoding("Unable to finish final frame") }
            writer.endSession(atSourceTime: end); video.markAsFinished(); audio?.markAsFinished()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void,Never>) in writer.finishWriting { continuation.resume() } }
            guard writer.status == .completed else { throw writer.error ?? CaptureMovieFailure.encoding("Unable to finalize movie") }
            setPhase(.finished); return url
        } catch CaptureMovieFailure.notRecording { throw CaptureMovieFailure.notRecording }
        catch { cancel(); throw error }
    }
    private func setPhase(_ phase: Phase) { lock.lock(); defer { lock.unlock() }; self.phase = phase }
    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        guard phase != .finished, phase != .cancelled else { return }
        phase = .cancelled; writer.cancelWriting(); lastBuffer = nil
    }
    deinit { if phase != .finished { writer.cancelWriting() } }
}
