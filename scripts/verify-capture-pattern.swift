// A separate process supplies known pixels and optional test audio to ScreenCaptureKit.
import AppKit
import AVFoundation

@MainActor final class CapturePatternWindow:NSPanel {
    override var canBecomeKey:Bool {true}
    override var canBecomeMain:Bool {true}
}

@MainActor final class CapturePatternDelegate:NSObject,NSApplicationDelegate {
    var windows:[NSWindow]=[]
    var timer:Timer?
    var tone:AVAudioPlayer?
    func applicationDidFinishLaunching(_ notification:Notification) {
        let menu=NSMenu(),item=NSMenuItem(),commands=NSMenu()
        for (title,action,key) in [("Play test tone",#selector(playTone),""),("Stop test tone",#selector(stopTone),""),("Quit test pattern",#selector(quit),"q")] {
            let entry=NSMenuItem(title:title,action:action,keyEquivalent:key);entry.target=self;commands.addItem(entry)
        }
        item.submenu=commands;menu.addItem(item);NSApp.mainMenu=menu
        for screen in NSScreen.screens {
            let window=CapturePatternWindow(contentRect:screen.frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false,screen:screen)
            window.isReleasedWhenClosed=false;window.isOpaque=true;window.backgroundColor = .black
            window.hidesOnDeactivate=false;window.becomesKeyOnlyIfNeeded=false
            window.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.canJoinAllApplications];window.level = .floating
            window.setFrame(screen.frame,display:true)
            window.title="Capture test pattern · "+screen.localizedName
            let view=CapturePatternView(frame:CGRect(origin:.zero,size:screen.frame.size));view.displayID=(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) ?? 0
            window.contentView=view;window.orderFrontRegardless();windows.append(window)
        }
        timer=Timer.scheduledTimer(withTimeInterval:0.1,repeats:true) { [weak self] _ in MainActor.assumeIsolated {
            guard let self else{return};self.windows.forEach{$0.contentView?.needsDisplay=true}
            let values=self.windows.map {window -> [String:Any] in ["title":window.title,"frame":NSStringFromRect(window.frame),"screen":window.screen?.localizedName ?? "","visible":window.isVisible,"activeSpace":window.isOnActiveSpace,"occlusionVisible":window.occlusionState.contains(.visible),"level":window.level.rawValue]}
            if let data=try? JSONSerialization.data(withJSONObject:values,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("pattern-probe.json"),options:.atomic)}
        } }
        windows.first?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
    @objc func playTone() {
        guard let url=Bundle.main.url(forResource:"test-tone",withExtension:"wav") else{return}
        tone=try? AVAudioPlayer(contentsOf:url);tone?.volume=0.03;tone?.numberOfLoops = -1;tone?.play()
    }
    @objc func stopTone() {tone?.stop();tone=nil}
    @objc func quit() {NSApp.terminate(nil)}
}
@MainActor final class CapturePatternView:NSView {
    var displayID:UInt32=0
    private let began=ProcessInfo.processInfo.systemUptime
    override func draw(_ dirtyRect:NSRect) {
        let colors:[NSColor]=[NSColor(srgbRed:1,green:0,blue:0,alpha:1),NSColor(srgbRed:0,green:1,blue:0,alpha:1),NSColor(srgbRed:0,green:0,blue:1,alpha:1),NSColor(srgbRed:1,green:1,blue:0,alpha:1)]
        let rects=[CGRect(x:0,y:bounds.midY,width:bounds.midX,height:bounds.midY),CGRect(x:bounds.midX,y:bounds.midY,width:bounds.midX,height:bounds.midY),CGRect(x:0,y:0,width:bounds.midX,height:bounds.midY),CGRect(x:bounds.midX,y:0,width:bounds.midX,height:bounds.midY)]
        for (i,rect) in rects.enumerated() {colors[(i+Int(displayID)%4)%4].setFill();rect.fill()}
        let elapsed=ProcessInfo.processInfo.systemUptime-began
        NSColor.white.setFill();CGRect(x:CGFloat(elapsed.truncatingRemainder(dividingBy:4)/4)*(bounds.width-100),y:bounds.midY-40,width:100,height:80).fill()
        let label=String(format:"Thermo live capture test · display %u · %.1f s",displayID,elapsed)
        (label as NSString).draw(at:CGPoint(x:40,y:bounds.midY+50),withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:24,weight:.bold),.foregroundColor:NSColor.black,.backgroundColor:NSColor.white])
    }
}
@main struct CapturePattern {
    @MainActor static func main() {
        let app=NSApplication.shared;app.setActivationPolicy(.regular);let delegate=CapturePatternDelegate();app.delegate=delegate
        withExtendedLifetime(delegate) {app.run()}
    }
}
