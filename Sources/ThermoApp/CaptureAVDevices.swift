import AppKit
import SwiftUI
@preconcurrency import AVFoundation
import CaptureCore
import Foundation
import ThermoL10n

struct CaptureDeviceChoice:Identifiable,Sendable { let id:String;let name:String }

private struct CaptureDeviceFailure:LocalizedError,Sendable {
    let message:String
    init(_ message:String) { self.message=message }
    var errorDescription:String? { tr(message) }
}

/// Owns only devices explicitly enabled for this recording. No device settings or system defaults are changed.
final class CaptureAVDevices:NSObject,AVCaptureVideoDataOutputSampleBufferDelegate,AVCaptureAudioDataOutputSampleBufferDelegate,@unchecked Sendable {
    let session=AVCaptureSession()
    private let queue=DispatchQueue(label:"dev.thermo.recording.devices")
    private let videoQueue=DispatchQueue(label:"dev.thermo.recording.camera")
    private let audioQueue=DispatchQueue(label:"dev.thermo.recording.microphone")
    private let lock=NSLock()
    private var stopping=false,reported=false
    private var observer:NSObjectProtocol?
    private let archive:CaptureFrameArchive
    private let failure:@Sendable(Error)->Void
    init(archive:CaptureFrameArchive,failure:@escaping @Sendable(Error)->Void) { self.archive=archive;self.failure=failure }
    private static func available(for type:AVMediaType) -> [AVCaptureDevice] {
        let kinds:[AVCaptureDevice.DeviceType]
        if #available(macOS 14,*) { kinds=type == .video ? [.builtInWideAngleCamera,.external,.continuityCamera] : [.microphone,.external] }
        else { kinds=type == .video ? [.builtInWideAngleCamera,.externalUnknown] : [.builtInMicrophone,.externalUnknown] }
        return AVCaptureDevice.DiscoverySession(deviceTypes:kinds,mediaType:type,position:.unspecified).devices
    }
    static func choices(for type:AVMediaType) -> [CaptureDeviceChoice] {
        available(for:type).map { .init(id:$0.uniqueID,name:$0.localizedName) }
    }
    static func authorize(camera:Bool,microphone:Bool) async throws {
        for (enabled,type,key) in [(camera,AVMediaType.video,"NSCameraUsageDescription"),(microphone,AVMediaType.audio,"NSMicrophoneUsageDescription")] where enabled {
            guard Bundle.main.object(forInfoDictionaryKey:key) != nil else { throw CaptureDeviceFailure("Use the bundled Thermo app for camera and microphone recording.") }
            switch AVCaptureDevice.authorizationStatus(for:type) {
            case .authorized:break
            case .notDetermined:
                guard await AVCaptureDevice.requestAccess(for:type) else { throw CaptureDeviceFailure(type == .video ? "Camera permission was not granted." : "Microphone permission was not granted.") }
            default:throw CaptureDeviceFailure(type == .video ? "Enable camera access for Thermo in System Settings." : "Enable microphone access for Thermo in System Settings.")
            }
            try Task.checkCancellation()
        }
    }
    func start(camera:Bool,microphone:Bool,cameraID:String,microphoneID:String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    session.beginConfiguration()
                    if camera,session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
                    do {
                        for (enabled,type,id) in [(camera,AVMediaType.video,cameraID),(microphone,AVMediaType.audio,microphoneID)] where enabled {
                            let device=id.isEmpty ? AVCaptureDevice.default(for:type) : Self.available(for:type).first { $0.uniqueID == id }
                            guard let device else { throw CaptureDeviceFailure(type == .video ? "No selected camera is available." : "No selected microphone is available.") }
                            let input=try AVCaptureDeviceInput(device:device)
                            guard session.canAddInput(input) else { throw CaptureDeviceFailure("The selected capture device could not be connected.") };session.addInput(input)
                            if type == .video {
                                let output=AVCaptureVideoDataOutput();output.videoSettings=[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA];output.alwaysDiscardsLateVideoFrames=true
                                output.setSampleBufferDelegate(self,queue:videoQueue)
                                guard session.canAddOutput(output) else { throw CaptureDeviceFailure("Camera output is unavailable.") };session.addOutput(output)
                            } else {
                                let output=AVCaptureAudioDataOutput();output.setSampleBufferDelegate(self,queue:audioQueue)
                                guard session.canAddOutput(output) else { throw CaptureDeviceFailure("Microphone output is unavailable.") };session.addOutput(output)
                            }
                        }
                    } catch { session.commitConfiguration();throw error }
                    session.commitConfiguration()
                    observer=NotificationCenter.default.addObserver(forName:.AVCaptureSessionRuntimeError,object:session,queue:nil) { [weak self] notification in
                        self?.report(notification.userInfo?[AVCaptureSessionErrorKey] as? Error ?? CaptureDeviceFailure("A capture device stopped unexpectedly."))
                    }
                    session.startRunning()
                    guard session.isRunning else { throw CaptureDeviceFailure("Camera or microphone capture did not start.") }
                    continuation.resume()
                } catch { session.stopRunning();continuation.resume(throwing:error) }
            }
        }
    }
    func captureOutput(_ output:AVCaptureOutput,didOutput sampleBuffer:CMSampleBuffer,from connection:AVCaptureConnection) {
        lock.lock();let stopped=stopping;lock.unlock()
        guard !stopped,sampleBuffer.isValid else { return }
        do {
            guard let clock=session.synchronizationClock else { throw CaptureDeviceFailure("The capture device clock is unavailable.") }
            let time=CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(sampleBuffer),from:clock,to:CMClockGetHostTimeClock())
            guard time.isNumeric else { throw CaptureMovieFailure.invalidTime }
            if output is AVCaptureVideoDataOutput,let image=sampleBuffer.imageBuffer { _=try archive.appendCamera(image,at:time) }
            else if output is AVCaptureAudioDataOutput { try archive.appendMicrophone(sampleBuffer,at:time) }
        } catch { report(error) }
    }
    private func report(_ error:Error) {
        lock.lock();let send = !reported && !stopping;reported=true;lock.unlock()
        if send { failure(error) }
    }
    func stop() async {
        await withCheckedContinuation { (continuation:CheckedContinuation<Void,Never>) in
            queue.async { [self] in
                lock.lock();stopping=true;lock.unlock();session.stopRunning()
                if let observer { NotificationCenter.default.removeObserver(observer) };observer=nil
                let group=DispatchGroup();group.enter();videoQueue.async { group.leave() };group.enter();audioQueue.async { group.leave() }
                group.notify(queue:queue) { continuation.resume() }
            }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}

struct CaptureDevicePreview:NSViewRepresentable {
    let session:AVCaptureSession
    func makeNSView(context:Context) -> NSView {
        let view=NSView();view.wantsLayer=true
        let layer=AVCaptureVideoPreviewLayer(session:session);layer.videoGravity = .resizeAspectFill;view.layer=layer
        return view
    }
    func updateNSView(_ view:NSView,context:Context) { (view.layer as? AVCaptureVideoPreviewLayer)?.session=session }
    static func dismantleNSView(_ view:NSView,coordinator:()) { (view.layer as? AVCaptureVideoPreviewLayer)?.session=nil }
}
