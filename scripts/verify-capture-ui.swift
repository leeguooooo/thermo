// Link with the debug ThermoApp module to exercise production capture UI without the helper.
@testable import ThermoApp
import AppKit
import AVFoundation
import CaptureCore
import ThermoL10n

@main struct CaptureReview {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        L10n.override = .simplifiedChinese
        let ctx = CGContext(data: nil,width: 900,height: 600,bitsPerComponent: 8,bytesPerRow: 0,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 0,y: 0,width: 900,height: 600))
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx,flipped: false)
        ("Thermo capture QA\n截图、标注、贴图\nOCR local recognition 12345" as NSString).draw(at: CGPoint(x: 60,y: 300), withAttributes: [.font: NSFont.systemFont(ofSize: 36), .foregroundColor: NSColor.black])
        if Bundle.main.object(forInfoDictionaryKey:"ThermoAnnotationReview") as? Bool == true {
            for x in 650..<850 {
                ctx.setFillColor((x%8 < 4 ? NSColor.systemBlue : NSColor.systemOrange).cgColor)
                ctx.fill(CGRect(x:x,y:60,width:1,height:200))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let menu = NSMenu(), top = NSMenuItem(), items = NSMenu()
        items.addItem(withTitle: "Quit QA",action: #selector(NSApplication.terminate(_:)),keyEquivalent: "q")
        top.submenu = items; menu.addItem(top); app.mainMenu = menu
        installStandardMenus()
        let image = ctx.makeImage()!
        var recordingWindow: CaptureRecordingWindow?
        var annotationWindow:CaptureEditor?
        var pinSession:CapturePinSession?
        if Bundle.main.object(forInfoDictionaryKey:"ThermoPinGroupsReview") as? Bool == true,
           let path=Bundle.main.object(forInfoDictionaryKey:"ThermoCaptureFixtureRoot") as? String {
            let root=URL(fileURLWithPath:path),session=CapturePinSession(store:.init(root:root.appendingPathComponent("pins")))
            pinSession=session
            do {
                if session.library.pins.isEmpty {
                    let first=try session.open(image)
                    session.windows[first]?.model.pinTitle="QA reference"
                    session.windows[first]?.model.document.append(.init(tool:.rectangle,points:[CGPoint(x:40,y:250),CGPoint(x:750,y:470)],color:.systemBlue))
                    try session.flush();let original=session.library.currentGroupID
                    _=try session.createGroup(name:"QA archive",color:"#FF8800")
                    let second=try session.open(image);session.windows[second]?.model.pinTitle="QA closed pin";session.closeAll()
                    try session.switchGroup(original)
                } else { session.restoreWindows() }
            } catch { session.issue=error.localizedDescription }
            session.showLibrary()
            let probe=Timer(timeInterval:0.3,repeats:true) { [weak session] _ in
                MainActor.assumeIsolated {
                    if let session,let data=try? JSONEncoder().encode(session.library) { try? data.write(to:root.appendingPathComponent("pins-probe.json"),options:.atomic) }
                }
            };RunLoop.main.add(probe,forMode:.common)
        } else if Bundle.main.object(forInfoDictionaryKey: "ThermoRecordingReview") as? Bool == true,
           let path = Bundle.main.object(forInfoDictionaryKey: "ThermoCaptureFixtureRoot") as? String {
            let root = URL(fileURLWithPath:path,isDirectory:true)
            let window = CaptureRecordingWindow(region:nil,store:CaptureRecordingDraftStore(root:root.appendingPathComponent("drafts")))
            recordingWindow = window; window.showWindow(nil)
            let probe = Timer(timeInterval:0.5,repeats:true) { [weak window] _ in
                MainActor.assumeIsolated {
                    guard let panel = window?.model.pendingSavePanel else { return }
                    let directory = panel.directoryURL?.path ?? "nil"
                    let values:[String:Any] = ["name":panel.nameFieldStringValue,"directory":directory,"url":panel.url?.path ?? "nil",
                        "allowed":panel.allowedContentTypes.map(\.identifier),"writable":FileManager.default.isWritableFile(atPath:directory),
                        "active":NSApp.isActive,"key":panel.isKeyWindow,"sheet":panel.isSheet,"visible":panel.isVisible,
                        "running":NSApp.isRunning,"finishedLaunching":NSRunningApplication.current.isFinishedLaunching,
                        "policy":NSApp.activationPolicy().rawValue,"recordingWindowVisible":window?.window?.isVisible ?? false]
                    if let data = try? JSONSerialization.data(withJSONObject:values,options:.sortedKeys) { try? data.write(to:root.appendingPathComponent("save-panel-probe.json"),options:.atomic) }
                }
            }
            RunLoop.main.add(probe,forMode:.common); RunLoop.main.add(probe,forMode:.modalPanel)
            Task {
                do {
                    let source = root.appendingPathComponent("fixture-"+UUID().uuidString+".mp4")
                    let ordinary=Bundle.main.object(forInfoDictionaryKey:"ThermoOrdinaryReview") as? Bool == true
                    let draft=ordinary ? try window.model.store.create(mode:.normal) : nil
                    let archive=try draft.map { try CaptureFrameArchive(root:window.model.store.archive($0.id),header:.init(width:320,height:240,fps:16,keyboardCapture:Bundle.main.object(forInfoDictionaryKey:"ThermoKeyboardReview") as? Bool == true ? .all : nil)) }
                    let writer=ordinary ? nil : try CaptureMovieWriter(url:source,width:320,height:240,fps:16)
                    for index in 0..<48 {
                        var result:CVPixelBuffer?
                        CVPixelBufferCreate(kCFAllocatorDefault,320,240,kCVPixelFormatType_32BGRA,[kCVPixelBufferCGImageCompatibilityKey:true,kCVPixelBufferCGBitmapContextCompatibilityKey:true] as CFDictionary,&result)
                        let buffer = result!
                        CVPixelBufferLockBaseAddress(buffer,[])
                        let ctx = CGContext(data:CVPixelBufferGetBaseAddress(buffer),width:320,height:240,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(buffer),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue)!
                        ctx.setFillColor(NSColor.systemBlue.cgColor); ctx.fill(CGRect(x:0,y:0,width:320,height:240))
                        ctx.setFillColor(NSColor.white.cgColor); ctx.fillEllipse(in:CGRect(x:index*5,y:100,width:50,height:50))
                        CVPixelBufferUnlockBaseAddress(buffer,[])
                        let time=CMTime(seconds:100+Double(index)/16,preferredTimescale:60000)
                        if let archive {
                            while try !archive.appendVideo(buffer,at:time) { try await Task.sleep(nanoseconds:1_000_000) }
                            archive.recordPointer(.init(x:0.1+Double(index)/60,y:0.75,buttons:(12...16).contains(index) ? 1 : 0),at:time)
                            if Bundle.main.object(forInfoDictionaryKey:"ThermoKeyboardReview") as? Bool == true {
                                if index == 8 { _=try archive.recordKey(label:"⌘C",shortcut:true,at:time) }
                                if index == 24 { _=try archive.recordKey(label:"A",shortcut:false,at:time) }
                                if index == 32 { _=try archive.recordKey(label:"⌥⇧↑",shortcut:true,at:time) }
                            }
                            if Bundle.main.object(forInfoDictionaryKey:"ThermoAVLayerReview") as? Bool == true {
                                var pixel:CVPixelBuffer?
                                CVPixelBufferCreate(kCFAllocatorDefault,160,120,kCVPixelFormatType_32BGRA,[kCVPixelBufferCGImageCompatibilityKey:true,kCVPixelBufferCGBitmapContextCompatibilityKey:true] as CFDictionary,&pixel)
                                let camera=pixel!;CVPixelBufferLockBaseAddress(camera,[])
                                let ctx=CGContext(data:CVPixelBufferGetBaseAddress(camera),width:160,height:120,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(camera),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue)!
                                ctx.setFillColor(NSColor.red.cgColor);ctx.fill(CGRect(x:0,y:0,width:160,height:120))
                                ctx.setFillColor(NSColor.green.cgColor);ctx.fill(CGRect(x:80,y:0,width:80,height:120))
                                CVPixelBufferUnlockBaseAddress(camera,[])
                                while try !archive.appendCamera(camera,at:time) { try await Task.sleep(nanoseconds:1_000_000) }
                            }
                        } else if let writer {
                            while try !writer.appendVideo(buffer,at:time) { try await Task.sleep(nanoseconds:1_000_000) }
                        }
                    }
                    if let archive,var draft {
                        if Bundle.main.object(forInfoDictionaryKey:"ThermoAVLayerReview") as? Bool == true {
                            for packet in 0..<30 { try archive.appendMicrophone(qaMicrophone(at:100+Double(packet)/10),at:CMTime(seconds:100+Double(packet)/10,preferredTimescale:60000)) }
                        }
                        _=try await archive.finish(at:CMTime(seconds:103,preferredTimescale:60000))
                        draft.status = .ready;try window.model.store.update(draft);window.model.reopen(draft)
                    } else if let writer {
                        _=try await writer.finish(at:CMTime(seconds:103,preferredTimescale:60000));await window.model.preview(source)
                    }
                    window.showWindow(nil)
                } catch { window.model.issue = error.localizedDescription }
            }
        } else if Bundle.main.object(forInfoDictionaryKey:"ThermoAnnotationReview") as? Bool == true {
            let window=CaptureEditor(image:image,onClose:{})
            var mosaic=CaptureAnnotation(tool:.mosaic,points:[CGPoint(x:50,y:290),CGPoint(x:650,y:470)],width:4);mosaic.options.strength=18
            window.model.document.append(mosaic)
            var lens=CaptureAnnotation(tool:.magnifier,points:[CGPoint(x:650,y:60),CGPoint(x:850,y:260)],color:.systemBlue,width:3);lens.options.zoom=2;lens.options.ellipse=true
            window.model.document.append(lens)
            window.model.tool = .select;window.model.selectAnnotation(0)
            annotationWindow=window;window.showWindow(nil)
        } else { let window=CaptureEditor(image:image,onClose:{});annotationWindow=window;window.showWindow(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now()+600) { app.terminate(nil) }
        withExtendedLifetime((recordingWindow,annotationWindow,pinSession)) { app.run() }
    }
}

private func qaMicrophone(at seconds:Double) throws -> CMSampleBuffer {
    var description=AudioStreamBasicDescription(mSampleRate:44100,mFormatID:kAudioFormatLinearPCM,mFormatFlags:kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked,mBytesPerPacket:4,mFramesPerPacket:1,mBytesPerFrame:4,mChannelsPerFrame:1,mBitsPerChannel:32,mReserved:0)
    var format:CMAudioFormatDescription?;CMAudioFormatDescriptionCreate(allocator:kCFAllocatorDefault,asbd:&description,layoutSize:0,layout:nil,magicCookieSize:0,magicCookie:nil,extensions:nil,formatDescriptionOut:&format)
    let values=(0..<4410).map { Float(sin(Double($0)*2*Double.pi*440/44100))*0.1 }
    var block:CMBlockBuffer?;CMBlockBufferCreateWithMemoryBlock(allocator:kCFAllocatorDefault,memoryBlock:nil,blockLength:values.count*4,blockAllocator:kCFAllocatorDefault,customBlockSource:nil,offsetToData:0,dataLength:values.count*4,flags:0,blockBufferOut:&block)
    values.withUnsafeBytes { _=CMBlockBufferReplaceDataBytes(with:$0.baseAddress!,blockBuffer:block!,offsetIntoDestination:0,dataLength:$0.count) }
    var timing=CMSampleTimingInfo(duration:CMTime(value:1,timescale:44100),presentationTimeStamp:CMTime(seconds:seconds,preferredTimescale:60000),decodeTimeStamp:.invalid),sample:CMSampleBuffer?
    CMSampleBufferCreateReady(allocator:kCFAllocatorDefault,dataBuffer:block!,formatDescription:format!,sampleCount:4410,sampleTimingEntryCount:1,sampleTimingArray:&timing,sampleSizeEntryCount:0,sampleSizeArray:nil,sampleBufferOut:&sample)
    guard let sample else { throw CaptureMovieFailure.noFrames };return sample
}
