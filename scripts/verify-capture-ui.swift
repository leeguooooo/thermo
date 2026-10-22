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
        NSGraphicsContext.restoreGraphicsState()
        let menu = NSMenu(), top = NSMenuItem(), items = NSMenu()
        items.addItem(withTitle: "Quit QA",action: #selector(NSApplication.terminate(_:)),keyEquivalent: "q")
        top.submenu = items; menu.addItem(top); app.mainMenu = menu
        installStandardMenus()
        let image = ctx.makeImage()!
        var recordingWindow: CaptureRecordingWindow?
        if Bundle.main.object(forInfoDictionaryKey: "ThermoRecordingReview") as? Bool == true,
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
                    let writer = try CaptureMovieWriter(url:source,width:320,height:240,fps:16)
                    for index in 0..<48 {
                        var result:CVPixelBuffer?
                        CVPixelBufferCreate(kCFAllocatorDefault,320,240,kCVPixelFormatType_32BGRA,[kCVPixelBufferCGImageCompatibilityKey:true,kCVPixelBufferCGBitmapContextCompatibilityKey:true] as CFDictionary,&result)
                        let buffer = result!
                        CVPixelBufferLockBaseAddress(buffer,[])
                        let ctx = CGContext(data:CVPixelBufferGetBaseAddress(buffer),width:320,height:240,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(buffer),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue)!
                        ctx.setFillColor(NSColor.systemBlue.cgColor); ctx.fill(CGRect(x:0,y:0,width:320,height:240))
                        ctx.setFillColor(NSColor.white.cgColor); ctx.fillEllipse(in:CGRect(x:index*5,y:100,width:50,height:50))
                        CVPixelBufferUnlockBaseAddress(buffer,[])
                        while try !writer.appendVideo(buffer,at:CMTime(seconds:100+Double(index)/16,preferredTimescale:60000)) { try await Task.sleep(nanoseconds:1_000_000) }
                    }
                    _ = try await writer.finish(at:CMTime(seconds:103,preferredTimescale:60000))
                    await window.model.preview(source)
                    window.showWindow(nil)
                } catch { window.model.issue = error.localizedDescription }
            }
        } else { CaptureWorkspace.shared.open(image) }
        DispatchQueue.main.asyncAfter(deadline: .now()+600) { app.terminate(nil) }
        withExtendedLifetime(recordingWindow) { app.run() }
    }
}
