import AgentCore
import AppKit
import Darwin
import Foundation
import ModuleHost
import ModuleKit
import PreviewCore
import Vision

private var failed=0
@MainActor private func check(_ condition:Bool,_ name:String){print("\(condition ? "PASS":"FAIL") \(name)");fflush(stdout);if !condition{failed += 1}}
@MainActor private func wait(_ seconds:TimeInterval,_ condition:()->Bool) async -> Bool {
    let end=Date().addingTimeInterval(seconds)
    while Date()<end{if condition(){return true};try? await Task.sleep(nanoseconds:20_000_000)}
    return condition()
}
private final class DeniedKernel:NSObject,KernelXPC {
    func request(_ capability:String,payload:Data,reply:@escaping @Sendable(Data?,String?)->Void){reply(nil,"No capabilities granted by the preview harness.")}
}
private func text(_ data:Data) throws -> String {
    let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate;request.usesLanguageCorrection=false
    try VNImageRequestHandler(data:data).perform([request])
    return request.results?.compactMap{$0.topCandidates(1).first?.string}.joined(separator:" ") ?? ""
}

@MainActor private func run(_ window:NSWindow) async {
    let app=Bundle.main.bundleURL,root=app.deletingLastPathComponent()
    let preview=Bundle.main.object(forInfoDictionaryKey:"PreviewModuleID") as? String ?? ""
    let probe=Bundle.main.object(forInfoDictionaryKey:"ProbeModuleID") as? String ?? ""
    let manager=ModuleManager(timing:.init(idleTimeout:2,firstBackoff:0.1,longestBackoff:1,stableRun:60))
    manager.kernel={_ in DeniedKernel()}
    do {
        await manager.load{_ in false}
        check(manager.problems.isEmpty,"module manifests and signatures accepted")
        check(manager.modules.count==2,"only the two owned fixture modules are loaded")
        manager.setEnabled(probe,true);manager.setEnabled(preview,true)
        let firstProbe=try await manager.run(probe,command:"ping")
        let probePID=(try JSONSerialization.jsonObject(with:firstProbe) as? [String:Any])?["pid"] as? Int
        check(probePID != nil,"unrelated probe started")
        let source=root.appendingPathComponent("inputs");try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        let marker="FDPREVIEW"+UUID().uuidString.replacingOccurrences(of:"-",with:"").prefix(8)
        let imageName="asset-"+UUID().uuidString+".png",document=source.appendingPathComponent(marker+".md")
        let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:32,pixelsHigh:32,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        try bitmap.representation(using:.png,properties:[:])!.write(to:source.appendingPathComponent(imageName))
        try Data("# \(marker)\n\nSelected **file input**.\n\n![asset](\(imageName))\n".utf8).write(to:document)
        let direct=try await manager.run(probe,command:"peek",arguments:JSONSerialization.data(withJSONObject:["path":document.path]))
        check((try JSONSerialization.jsonObject(with:direct) as? [String:Any])?["readable"] as? Bool == false,"sandbox probe cannot directly read the host fixture file")
        let job=UUID(),input=PreviewInput(id:job,kind:.file,name:document.lastPathComponent,originalURL:document.absoluteString,language:"en")
        let file=try FileHandle(forReadingFrom:document)
        let prepared=try await manager.prepareInput(preview,file:file,metadata:input.data());try file.close()
        let receipt=try JSONSerialization.jsonObject(with:prepared) as? [String:Any]
        let expected=source.appendingPathComponent(imageName).absoluteString
        check((receipt?["needsAssets"] as? [String])?.contains(expected)==true,"sandbox renderer read and parsed the transferred descriptor")
        let scope=try PreviewResourceScope(root:source),asset=try scope.openFile(source.appendingPathComponent(imageName),imageOnly:true,maxBytes:8*1024*1024)
        _=try await manager.prepareInput(preview,file:asset,metadata:PreviewInput(id:job,kind:.asset,name:imageName,resourceURL:expected).data());try asset.close()
        let rendered=try await manager.prepareInput(preview,file:nil,metadata:PreviewInput(id:job,kind:.render,name:input.name).data())
        check((try JSONSerialization.jsonObject(with:rendered) as? [String:Any])?["ready"] as? Bool == true,"associated image input and Markdown render completed")
        let writable=try FileHandle(forUpdating:document)
        do{_=try await manager.prepareInput(preview,file:writable,metadata:input.data());check(false,"writable descriptor refused")}catch{check(true,"writable descriptor refused")};try writable.close()
        let pipe=Pipe()
        do{_=try await manager.prepareInput(preview,file:pipe.fileHandleForReading,metadata:input.data());check(false,"pipe descriptor refused")}catch{check(true,"pipe descriptor refused")}
        let scene=try manager.attach(preview,scene:"preview")
        window.contentViewController=scene.controller;scene.controller.view.frame=NSRect(x:0,y:0,width:820,height:620)
        check(await wait(10){scene.active},"remote preview scene activated")
        try await Task.sleep(nanoseconds:1_000_000_000)
        let png=try await scene.snapshot();try png.write(to:root.appendingPathComponent("preview.png"))
        let visible=try await Task.detached{try text(png)}.value
        check(visible.uppercased().contains(marker.uppercased()),"remote scene displays the selected input (OCR)")
        let own=manager.modules.first(where:{$0.manifest.id == preview})?.pid
        let identity=own.flatMap{ProcessTable.identity($0)}
        let expectedPath=app.appendingPathComponent("Contents/Extensions/Preview.appex/Contents/MacOS/Preview").path
        if let own,let identity,identity.uid == getuid(),identity.executable == expectedPath,ProcessTable.identity(own)==identity {
            check(kill(own,SIGKILL)==0,"only the identity-checked owned preview fixture was crashed")
        }else{check(false,"owned preview identity matched before crash")}
        check(await wait(8){(manager.modules.first{$0.manifest.id == preview}?.crashes ?? 0)>0},"renderer crash observed without host termination")
        let after=try await manager.run(probe,command:"ping")
        let afterPID=(try JSONSerialization.jsonObject(with:after) as? [String:Any])?["pid"] as? Int
        check(afterPID==probePID,"unrelated module stayed alive across the renderer crash")
        manager.detach(scene);window.contentViewController=nil
        manager.setEnabled(preview,false);manager.setEnabled(probe,false)
        check(await wait(8){manager.modules.allSatisfy{$0.pid == nil && !$0.scheduled}},"owned module processes and wakeups retired")
        let result:[String:Any]=["failures":failed,"hostPID":getpid(),"source":"preview harness","scope":"owned fixtures, sandbox FD handoff, remote scene, controlled child crash; no personal files or input events"]
        try JSONSerialization.data(withJSONObject:result,options:.prettyPrinted).write(to:root.appendingPathComponent("result.json"))
    }catch{check(false,"scenario error: \(error)")}
    print(failed==0 ? "PASS PREVIEW HARNESS":"FAILED PREVIEW HARNESS \(failed)");fflush(stdout);exit(failed==0 ? 0:1)
}
private final class Delegate:NSObject,NSApplicationDelegate {
    var window:NSWindow!
    func applicationDidFinishLaunching(_ notification:Notification) {
        window=NSWindow(contentRect:NSRect(x:-9000,y:-9000,width:820,height:620),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.orderBack(nil)
        Task{@MainActor in await run(window)}
        DispatchQueue.main.asyncAfter(deadline:.now()+100){print("FAILED timeout");fflush(stdout);exit(2)}
    }
}
let app=NSApplication.shared
let delegate=Delegate();app.delegate=delegate;app.setActivationPolicy(.prohibited);app.run()
