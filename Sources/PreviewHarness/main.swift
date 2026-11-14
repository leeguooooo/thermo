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
        let marker="FDPREVIEW"+String(UUID().uuidString.replacingOccurrences(of:"-",with:"").prefix(8).map { Character(UnicodeScalar(65 + Int(String($0),radix:16)! % 8)!) })
        let imageName="asset-"+UUID().uuidString+".png",document=source.appendingPathComponent(marker+".md")
        let colorSpace=CGColorSpace(name:CGColorSpace.sRGB)!
        let canvas=CGContext(data:nil,width:32,height:32,bitsPerComponent:8,bytesPerRow:128,space:colorSpace,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        canvas.setFillColor(CGColor(colorSpace:colorSpace,components:[1,0,1,1])!);canvas.fill(CGRect(x:0,y:0,width:32,height:32))
        let bitmap=NSBitmapImageRep(cgImage:canvas.makeImage()!)
        try bitmap.representation(using:.png,properties:[:])!.write(to:source.appendingPathComponent(imageName))
        try Data("# \(marker)\n\nSandbox document rendered. Selected **file input**.\n\n![asset](\(imageName))\n".utf8).write(to:document)
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
        var visible="", sceneReady=false
        let deadline=Date().addingTimeInterval(12)
        repeat {
            do {
                let png=try await scene.snapshot()
                try png.write(to:root.appendingPathComponent("preview.png"))
                visible=try await Task.detached{try text(png)}.value
                sceneReady=visible.uppercased().contains(marker.uppercased()) && visible.lowercased().contains("sandbox document rendered")
            } catch { visible=String(describing:error) }
            if !sceneReady {try await Task.sleep(nanoseconds:250_000_000)}
        } while !sceneReady && Date()<deadline
        try visible.write(to:root.appendingPathComponent("preview-ocr.txt"),atomically:true,encoding:.utf8)
        check(sceneReady,"remote scene displays the selected input and rendered document (OCR)")
        var imagePixels=0,bestScore:CGFloat = -10,bestColor:[CGFloat]=[]
        if let png=try? Data(contentsOf:root.appendingPathComponent("preview.png")),let bitmap=NSBitmapImageRep(data:png) {
            for y in stride(from:0,to:bitmap.pixelsHigh,by:4) {for x in stride(from:0,to:bitmap.pixelsWide,by:4) {
                if let color=bitmap.colorAt(x:x,y:y)?.usingColorSpace(.sRGB) {
                    let score=color.redComponent+color.blueComponent-color.greenComponent
                    if score>bestScore{bestScore=score;bestColor=[color.redComponent,color.greenComponent,color.blueComponent]}
                    if color.redComponent>0.8,color.blueComponent>0.8,color.greenComponent<0.2 {imagePixels += 1}
                }
            }}
        }
        try JSONSerialization.data(withJSONObject:["matchingSamples":imagePixels,"bestRGB":bestColor],options:.prettyPrinted).write(to:root.appendingPathComponent("image-inspection.json"))
        check(imagePixels>5,"associated image is visible in the sandboxed remote scene")
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
private let delegate=Delegate()
app.delegate=delegate;app.setActivationPolicy(.prohibited);app.run()
