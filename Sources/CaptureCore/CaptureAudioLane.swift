import AVFoundation
import Foundation

/// A separately editable PCM lane, normalized to 48 kHz stereo without changing device settings.
final class CaptureAudioLane {
    private let url:URL
    private let format=AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:48000,channels:2,interleaved:false)!
    private var file:AVAudioFile?
    private var inputFormat:AVAudioFormat?
    private var converter:AVAudioConverter?
    private var frames:AVAudioFramePosition=0
    init(url:URL) { self.url=url }
    func append(_ sample:CMSampleBuffer,at seconds:Double) throws {
        guard seconds.isFinite,seconds >= 0,seconds*48000 < Double(Int64.max),let description=sample.formatDescription else { throw CaptureMovieFailure.invalidTime }
        let input=AVAudioFormat(cmAudioFormatDescription:description),count=CMSampleBufferGetNumSamples(sample)
        guard (8000...192000).contains(input.sampleRate),(1...2).contains(input.channelCount),count > 0,count <= 384000,
              let pcm=AVAudioPCMBuffer(pcmFormat:input,frameCapacity:AVAudioFrameCount(count)) else { throw CaptureMovieFailure.invalidConfiguration }
        pcm.frameLength=AVAudioFrameCount(count)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample,at:0,frameCount:Int32(count),into:pcm.mutableAudioBufferList) == noErr else { throw CaptureMovieFailure.encoding("Unable to read audio samples") }
        let normalized:AVAudioPCMBuffer
        if input == format { converter=nil;inputFormat=input;normalized=pcm }
        else {
            if inputFormat != input {
                guard let converter=AVAudioConverter(from:input,to:format) else { throw CaptureMovieFailure.encoding("Unable to convert the capture audio format.") }
                converter.primeMethod = .none;converter.channelMap=input.channelCount == 1 ? [0,0] : [0,1];self.converter=converter;inputFormat=input
            }
            guard let converter,let output=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(ceil(Double(count)*48000/input.sampleRate))) else { throw CaptureFailure.exportFailed }
            if input.sampleRate == 48000 { try converter.convert(to:output,from:pcm) }
            else {
                var supplied=false,error:NSError?
                let status=converter.convert(to:output,error:&error) { _,state in
                    if supplied { state.pointee = .noDataNow;return nil }
                    supplied=true;state.pointee = .haveData;return pcm
                }
                guard status != .error else { throw error ?? CaptureMovieFailure.encoding("Audio conversion failed.") }
            }
            normalized=output
        }
        guard normalized.frameLength > 0 else { return }
        if file == nil { file=try AVAudioFile(forWriting:url,settings:format.settings,commonFormat:.pcmFormatFloat32,interleaved:false) }
        guard let file else { throw CaptureFailure.exportFailed }
        let target=AVAudioFramePosition((seconds*48000).rounded()),skip=max(0,Int(frames-target))
        guard skip < Int(normalized.frameLength) else { return }
        while target > frames {
            let length=AVAudioFrameCount(min(target-frames,4800)),silence=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(min(target-frames,4800)))!
            silence.frameLength=length
            for buffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) { if let data=buffer.mData { memset(data,0,Int(buffer.mDataByteSize)) } }
            try file.write(from:silence);frames += AVAudioFramePosition(length)
        }
        if skip == 0 { try file.write(from:normalized);frames += AVAudioFramePosition(normalized.frameLength) }
        else {
            let count=Int(normalized.frameLength)-skip,trimmed=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(count))!
            trimmed.frameLength=AVAudioFrameCount(count)
            for channel in 0..<2 { memcpy(trimmed.floatChannelData![channel],normalized.floatChannelData![channel]+skip,count*4) }
            try file.write(from:trimmed);frames += AVAudioFramePosition(count)
        }
    }
    func close() { file=nil;converter=nil;inputFormat=nil }
}
