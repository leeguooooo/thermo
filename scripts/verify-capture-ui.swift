// Link with the debug ThermoApp module to exercise production capture UI without the helper.
@testable import ThermoApp
import AppKit
import AVFoundation
import CaptureCore
import CryptoKit
import AgentCore
import ThermoKit
import CaptureScriptCore
import ThermoL10n
import SwiftUI

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
        var captureWorkspace:CaptureWorkspace?
        var shortcutModel:CaptureShortcutModel?
        var cliHost:CaptureCLIHost?
        var cliServer:AppControlServer?
        var screenshotReviewWindow:NSWindowController?
        if Bundle.main.object(forInfoDictionaryKey:"ThermoScreenshotReview") as? Bool == true,
           let path=Bundle.main.object(forInfoDictionaryKey:"ThermoCaptureFixtureRoot") as? String {
            let root=URL(fileURLWithPath:path),session=CapturePinSession(store:.init(root:root.appendingPathComponent("pins"))),workspace=CaptureWorkspace(pinSession:session)
            workspace.saving=CaptureSaveModel(read:{nil},write:{_ in})
            captureWorkspace=workspace;pinSession=session
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:720,height:500),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            window.title="QA screenshot target";window.isReleasedWhenClosed=false
            window.contentView=NSHostingView(rootView:CaptureScreenshotQA(workspace:workspace,root:root))
            screenshotReviewWindow=NSWindowController(window:window);window.center();window.makeKeyAndOrderFront(nil)
        } else if Bundle.main.object(forInfoDictionaryKey:"ThermoPassthroughReview") as? Bool == true,
                  let path=Bundle.main.object(forInfoDictionaryKey:"ThermoCaptureFixtureRoot") as? String {
            let root=URL(fileURLWithPath:path),session=CapturePinSession(store:.init(root:root.appendingPathComponent("pins"))),workspace=CaptureWorkspace(pinSession:session)
            workspace.saving=CaptureSaveModel(read:{nil},write:{_ in});pinSession=session;captureWorkspace=workspace
            do {
                if session.library.pins.isEmpty {
                    if Bundle.main.object(forInfoDictionaryKey:"ThermoBatchExportReview") as? Bool == true {
                        let first=session.library.currentGroupID
                        let a=try session.open(image);session.windows[a]?.model.pinTitle="../same / title";try session.windows[a]?.model.applyColorAction(.grayscale)
                        let b=try session.open(image);session.windows[b]?.model.pinTitle="../same / title"
                        _=try session.open(CapturePinContent.text(.init(plain:"Excluded typed QA pin")))
                        let closed=try session.open(image);session.windows[closed]?.window?.performClose(nil)
                        _=try session.createGroup(name:"Other QA group",color:nil,switchTo:true)
                        let other=try session.open(image);session.windows[other]?.model.pinTitle="Other image";session.windows[other]?.model.locked=true
                        try session.switchGroup(first);try session.setAllHidden(true);try session.flush()
                    } else {let id=try session.open(image);session.windows[id]?.model.pinTitle="QA passthrough pin";try session.flush()}
                }
                else {session.restoreWindows()}
            } catch {session.issue=error.localizedDescription}
            session.showLibrary()
            let probe=Timer(timeInterval:0.25,repeats:true) { [weak session] _ in
                MainActor.assumeIsolated {
                    guard let session else{return}
                    let values:[[String:Any]]=session.windows.map {id,editor in
                        ["id":id.uuidString,"mousePassthrough":editor.model.mousePassthrough,"ignoresMouseEvents":editor.window?.ignoresMouseEvents ?? false,"title":editor.window?.title ?? "","visible":editor.window?.isVisible ?? false,"revision":editor.model.revision,"imageSize":[editor.model.document.image.width,editor.model.document.image.height]]
                    }
                    let record:[String:Any]=["batchExport":["allGroups":session.batchExport.allGroups,"selectedGroupID":session.batchExport.selectedGroupID?.uuidString ?? "","format":session.batchExport.format.rawValue,"running":session.batchExport.running,"completed":session.batchExport.completed,"total":session.batchExport.total,"folder":session.batchExport.result?.folder.path ?? "","issue":session.batchExport.issue ?? ""],"pins":values,"savedPins":session.library.pins.count,"issue":session.issue ?? "","libraryVisible":NSApp.windows.contains{$0.title == tr("Pin groups and history") && $0.isVisible}]
                    if let data=try? JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:root.appendingPathComponent("passthrough-probe.json"),options:.atomic)}
                }
            };RunLoop.main.add(probe,forMode:.common)
        } else if Bundle.main.object(forInfoDictionaryKey:"ThermoSavingReview") as? Bool == true,
           let path=Bundle.main.object(forInfoDictionaryKey:"ThermoCaptureFixtureRoot") as? String {
            let root=URL(fileURLWithPath:path),session=CapturePinSession(store:.init(root:root.appendingPathComponent("pins"))),workspace=CaptureWorkspace(pinSession:session)
            let file=root.appendingPathComponent("saving.json")
            workspace.saving=CaptureSaveModel(read:{try? Data(contentsOf:file)},write:{try $0.write(to:file,options:.atomic)})
            if !FileManager.default.fileExists(atPath:file.path) {
                var options=CaptureSaveSettings();options.quick.directory=root.appendingPathComponent("quick").path;options.automatic.directory=root.appendingPathComponent("automatic").path
                try? FileManager.default.createDirectory(atPath:options.quick.directory,withIntermediateDirectories:true)
                try? FileManager.default.createDirectory(atPath:options.automatic.directory,withIntermediateDirectories:true)
                _=workspace.saving.apply(options)
            }
            session.restoreWindows();pinSession=session;captureWorkspace=workspace
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:850),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            window.title="QA saving and after-actions";window.isReleasedWhenClosed=false
            window.contentView=NSHostingView(rootView:CaptureSavingQA(workspace:workspace,image:image,root:root));window.center();window.makeKeyAndOrderFront(nil)
        } else if Bundle.main.object(forInfoDictionaryKey:"ThermoShortcutsReview") as? Bool == true,
           let path=Bundle.main.object(forInfoDictionaryKey:"ThermoCaptureFixtureRoot") as? String {
            let root=URL(fileURLWithPath:path),session=CapturePinSession(store:.init(root:root.appendingPathComponent("pins"))),workspace=CaptureWorkspace(pinSession:session)
            let settingsFile=root.appendingPathComponent("shortcuts.json")
            var initial=CaptureActionSettings(entries:[
                .init(title:"QA pin lock",action:.toggleLock,scope:.pin,shortcut:.init(keyCode:37,modifiers:0,keyLabel:"L")),
                .init(title:"QA hide/show",action:.togglePins),
                .init(title:"QA show pin",action:.showPin),
                .init(title:"QA settings",action:.shortcutSettings,scope:.pin,shortcut:.init(keyCode:40,modifiers:0,keyLabel:"K"))])
            if Bundle.main.object(forInfoDictionaryKey:"ThermoScriptReview") as? Bool == true {
                initial = .init(entries:[.init(title:"QA script sequence",action:.script,script:"const before=thermo.perform('status');for(let i=0;i<3;i++)thermo.perform('toggleLock');thermo.perform('hidePins');thermo.perform('showPins');console.log('pins',before.pins);return thermo.perform('status');")])
            }
            let model=CaptureShortcutModel(backend:CaptureShortcutModel.backend(),read:{ (try? Data(contentsOf:settingsFile)) ?? (try? initial.data()) },write:{ try $0.write(to:settingsFile,options:.atomic) },pinFocused:{ [weak workspace] in workspace?.pinSession.focusedEditor() != nil },execute:{ [weak workspace] action in
                guard let workspace else { throw CaptureActionFailure.noPin }
                let before:[String:Any] = ["action":action.rawValue,"windows":workspace.pinSession.windows.count,"target":workspace.pinSession.activeEditor()?.model.pinTitle ?? "none","sessionIssue":workspace.pinSession.issue ?? "none"]
                if let data=try? JSONSerialization.data(withJSONObject:before) { try? data.write(to:root.appendingPathComponent("action-probe.json"),options:.atomic) }
                try workspace.perform(action)
            })
            model.executeScript={ [weak workspace] source in
                guard let workspace else{throw CaptureScriptFailure.unavailable}
                let result=try await workspace.executeScript(source)
                struct Record:Codable {let value:CaptureScriptValue;let logs:[String]}
                try JSONEncoder().encode(Record(value:result.value,logs:result.logs)).write(to:root.appendingPathComponent("script-result.json"),options:.atomic)
                return result
            }
            if Bundle.main.object(forInfoDictionaryKey:"ThermoCaptureCLIReview") as? Bool == true {
                do {
                    let host=CaptureCLIHost(workspace:workspace),directory=root.appendingPathComponent("control"),cli=Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/thermo")
                    let trust=try LocalControlPeerTrust(team:CodeSignature.teamIdentifier(),developmentExecutable:cli)
                    cliHost=host;cliServer=try AppControlServer(directory:directory,authorize:{trust.accepts(auditToken:$0)}) {request,reply in Task{@MainActor in reply(await host.handle(request))}}
                    let info=["directory":directory.path,"cli":cli.path]
                    try JSONSerialization.data(withJSONObject:info).write(to:root.appendingPathComponent("control-info.json"),options:.atomic)
                } catch {workspace.saving.issue=error.localizedDescription}
            }
            workspace.shortcuts=model;captureWorkspace=workspace;shortcutModel=model;pinSession=session
            do {
                if session.library.pins.isEmpty { let id=try session.open(.text(.init(plain:"Shortcut action QA")));session.windows[id]?.model.pinTitle="QA shortcut pin";try session.flush() }
                else { session.restoreWindows();if session.windows.isEmpty { try session.restore() } }
                workspace.showActionSettings()
                let initialProbe:[String:Any] = ["windows":session.windows.count,"sessionIssue":session.issue ?? "none","target":session.activeEditor()?.model.pinTitle ?? "none"]
                if let data=try? JSONSerialization.data(withJSONObject:initialProbe) { try? data.write(to:root.appendingPathComponent("startup-probe.json"),options:.atomic) }
            } catch { session.issue=error.localizedDescription;session.showLibrary() }
        } else if Bundle.main.object(forInfoDictionaryKey:"ThermoLaTeXReview") as? Bool == true,
           let path=Bundle.main.object(forInfoDictionaryKey:"ThermoCaptureFixtureRoot") as? String {
            let root=URL(fileURLWithPath:path),session=CapturePinSession(store:.init(root:root.appendingPathComponent("pins")));pinSession=session
            do {
                if session.library.pins.isEmpty {
                    let source="$$\\begin{aligned}E&=mc^2\\\\\\int_0^1 x^2\\,dx&=\\frac{1}{3}\\end{aligned}$$"
                    let first=try session.open(.latex(.init(source:source)));session.windows[first]?.model.pinTitle="QA formula"
                    var matrix=CaptureLaTeX(source:"\\begin{pmatrix}a&b\\\\c&d\\end{pmatrix}");matrix.foreground="#2244AA";matrix.transparentBackground=false
                    let second=try session.open(.latex(matrix));session.windows[second]?.model.pinTitle="QA matrix";try session.flush()
                } else { session.restoreWindows() }
                if Bundle.main.object(forInfoDictionaryKey:"ThermoWordMathReview") as? Bool == true {
                    let fixtures=[("fraction","\\frac{1}{\\sqrt{x}}"),("integral","\\int_0^1 x^2\\,dx"),("matrix","\\begin{pmatrix}a&b\\\\c&d\\end{pmatrix}"),("aligned","\\begin{aligned}a&=b+c\\\\d&=e\\end{aligned}"),("scripts","x_1^2+\\sqrt[3]{y}"),("accents","\\hat{x}+\\overline{y}"),("chemistry","\\ce{H2O}"),("isotope","\\ce{^{14}_{6}C}"),("binomial","\\binom{n}{k}"),("enclosures","\\cancel{x}+\\boxed{y}"),("functions","\\sin x+\\lim_{n\\to\\infty} x_n"),("braces","\\overbrace{a+b}^{n}"),("cases","\\begin{cases}x&x>0\\\\0&x=0\\end{cases}")]
                    let directory=root.appendingPathComponent("word-fixtures");try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                    for (name,source) in fixtures { try CaptureWordDocument.save(.init(source:source),to:directory.appendingPathComponent(name+".docx")) }
                }
                session.showLibrary()
            } catch { session.issue=error.localizedDescription;session.showLibrary() }
        } else if Bundle.main.object(forInfoDictionaryKey:"ThermoTypedPinsReview") as? Bool == true,
           let path=Bundle.main.object(forInfoDictionaryKey:"ThermoCaptureFixtureRoot") as? String {
            let root=URL(fileURLWithPath:path),session=CapturePinSession(store:.init(root:root.appendingPathComponent("pins")));pinSession=session
            do {
                if session.library.pins.isEmpty {
                    let rich=NSAttributedString(string:"RTF rich text QA\n中文可选文字",attributes:[.font:NSFont.boldSystemFont(ofSize:28),.foregroundColor:NSColor.systemRed])
                    let rtf=try rich.data(from:NSRange(location:0,length:rich.length),documentAttributes:[.documentType:NSAttributedString.DocumentType.rtf])
                    let text=try session.open(.text(.init(plain:rich.string,rtf:rtf)));session.windows[text]?.model.pinTitle="QA rich text"
                    let endpoint=Bundle.main.object(forInfoDictionaryKey:"ThermoHTMLProbeURL") as? String ?? "http://127.0.0.1:49379/probe"
                    let html="<h1 style='color:#CC0000'>HTML formatting QA</h1><p>HTML selectable 中文</p><script>document.body.innerHTML='SCRIPT RAN';fetch('"+endpoint+"/script')</script><img src='"+endpoint+"/image'><link rel='stylesheet' href='"+endpoint+"/style'><iframe src='"+endpoint+"/frame'></iframe>"
                    let web=try session.open(.text(.init(plain:"",html:html)));session.windows[web]?.model.pinTitle="QA HTML"
                    let file=root.appendingPathComponent("fixture.txt");try Data("Local file preview QA\n中文文件内容".utf8).write(to:file)
                    let folder=root.appendingPathComponent("fixture-folder");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                    let files=try session.open(.files([try .init(url:file),try .init(url:folder)]));session.windows[files]?.model.pinTitle="QA files"
                    let color=try session.open(.color(.init(red:41,green:184,blue:219)));session.windows[color]?.model.pinTitle="QA color"
                    try session.flush()
                } else { session.restoreWindows() }
                session.showLibrary()
            } catch { session.issue=error.localizedDescription;session.showLibrary() }
        } else if Bundle.main.object(forInfoDictionaryKey:"ThermoPinGroupsReview") as? Bool == true,
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
        } else if Bundle.main.object(forInfoDictionaryKey:"ThermoAnnotationReview") as? Bool == true || Bundle.main.object(forInfoDictionaryKey:"ThermoOCRReview") as? Bool == true {
            let board=Bundle.main.object(forInfoDictionaryKey:"ThermoOCRReview") as? Bool == true ? NSPasteboard.withUniqueName() : nil
            weak var reviewModel:CaptureEditorModel?
            let window=CaptureEditor(image:image,onClose:{reviewModel?.copyPasteboard=nil;board?.releaseGlobally()})
            reviewModel=window.model
            window.model.copyPasteboard=board
            if Bundle.main.object(forInfoDictionaryKey:"ThermoAnnotationReview") as? Bool == true {
            var mosaic=CaptureAnnotation(tool:.mosaic,points:[CGPoint(x:50,y:290),CGPoint(x:650,y:470)],width:4);mosaic.options.strength=18
            window.model.document.append(mosaic)
            var lens=CaptureAnnotation(tool:.magnifier,points:[CGPoint(x:650,y:60),CGPoint(x:850,y:260)],color:.systemBlue,width:3);lens.options.zoom=2;lens.options.ellipse=true
            window.model.document.append(lens)
            window.model.tool = .select;window.model.selectAnnotation(0)
            }
            if Bundle.main.object(forInfoDictionaryKey:"ThermoCropReview") as? Bool == true {
                window.model.tool = .crop;window.model.setCropSelection(CGRect(x:50,y:60,width:400,height:300))
            }
            if Bundle.main.object(forInfoDictionaryKey:"ThermoAnnotationStylesReview") as? Bool == true {
                window.model.document.append(CaptureAnnotation(tool:.arrow,points:[CGPoint(x:150,y:220),CGPoint(x:600,y:220)],width:4))
                window.model.tool = .select;window.model.selectAnnotation(2)
            }
            annotationWindow=window;window.showWindow(nil)
            if board != nil {DispatchQueue.main.async {app.activate(ignoringOtherApps:true);window.window?.makeKeyAndOrderFront(nil)}}
            if let path=Bundle.main.object(forInfoDictionaryKey:"ThermoCaptureFixtureRoot") as? String {
                let probe=Timer(timeInterval:0.25,repeats:true) { [weak model=window.model,weak panel=window.window] _ in
                    MainActor.assumeIsolated {
                        guard let model else{return}
                        var record:[String:Any] = ["selected":model.selectedAnnotations.sorted(),"objects":model.document.annotations.map {item in
                            ["tool":item.tool.rawValue,"points":item.points.map{[Double($0.x),Double($0.y)]},"width":Double(item.width),"label":item.numberLabel,"options":["lineStart":item.options.lineStart.rawValue,"lineEnd":item.options.lineEnd.rawValue,"lineJoin":item.options.lineJoin.rawValue,"lineCap":item.options.lineCap.rawValue,"comment":item.options.arrowComment,"start":item.options.arrowStart.rawValue,"end":item.options.arrowEnd.rawValue,"line":item.options.linePattern.rawValue,"numberShape":item.options.numberShape.rawValue,"numberFormat":item.options.numberFormat.rawValue,"numberFilled":item.options.numberFilled,"numberLeader":item.options.numberLeader,"numberValue":item.options.numberValue ?? -1]] as [String:Any]
                        },"canUndo":model.document.canUndo,"canRedo":model.document.canRedo,"pan":[Double(model.pan.x),Double(model.pan.y)],"zoom":model.zoom,"revision":model.revision,"renderCacheBytes":CaptureRenderCache.shared.cachedBytes,"windowVisible":panel?.isVisible ?? false,"windowKey":panel?.isKeyWindow ?? false,"appActive":NSApp.isActive]
                        record["cropSelection"]=model.cropSelection.map{[Double($0.minX),Double($0.minY),Double($0.width),Double($0.height)]} ?? [];record["locked"]=model.locked;record["windowMovable"]=panel?.isMovable ?? false
                        record["imageAdjustments"]=["grayscale":model.document.imageAdjustments.grayscale,"inverted":model.document.imageAdjustments.inverted,"brightness":model.document.imageAdjustments.brightness];record["imageSize"]=[model.document.image.width,model.document.image.height];record["imageDisplayScale"]=model.imageDisplayScale?() ?? -1;record["opacity"]=model.opacity
                        if model.copyPasteboard != nil {
                            record["recognized"]=model.recognition;record["selectingOCRText"]=model.selectingOCRText
                            record["selectedOCRText"]=model.selectedOCRText;record["copiedOCRText"]=model.copyPasteboard?.string(forType:.string) ?? ""
                            let png=model.copyPasteboard?.data(forType:.png)
                            record["copiedPNGBytes"]=png?.count ?? 0
                            if let png,let rep=NSBitmapImageRep(data:png) {record["copiedPNGSize"]=[rep.pixelsWide,rep.pixelsHigh];record["copiedPNGCornerAlpha"]=rep.colorAt(x:0,y:0)?.alphaComponent ?? -1}
                            record["copiedPNGHash"]=png.map{SHA256.hash(data:$0).map{String(format:"%02x",$0)}.joined()} ?? ""
                            record["segments"]=model.ocrSegments.map {segment in ["range":[segment.range.location,segment.range.length],"box":[Double(segment.bounds.minX),Double(segment.bounds.minY),Double(segment.bounds.width),Double(segment.bounds.height)]] as [String:Any]}
                        }
                        if let data=try? JSONSerialization.data(withJSONObject:record,options:.sortedKeys) {try? data.write(to:URL(fileURLWithPath:path).appendingPathComponent("annotation-probe.json"),options:.atomic)}
                    }
                };RunLoop.main.add(probe,forMode:.common)
            }
        } else { let window=CaptureEditor(image:image,onClose:{});annotationWindow=window;window.showWindow(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now()+600) { app.terminate(nil) }
        withExtendedLifetime((recordingWindow,annotationWindow,pinSession,captureWorkspace,shortcutModel,cliHost,cliServer,screenshotReviewWindow)) { app.run() }
    }
}

private struct CaptureScreenshotQA:View {
    @ObservedObject var workspace:CaptureWorkspace
    let root:URL
    @State private var task:Task<Void,Never>?
    @State private var result="Not started"
    @State private var attempts=0
    private let clock=Timer.publish(every:0.25,on:.main,in:.common).autoconnect()
    var body:some View {
        VStack(spacing:18) {
            Text("THERMO SCREENSHOT QA 12345").font(.system(size:28,weight:.bold))
            Text("合成截图测试窗口 · Region / Space for window / Esc to cancel")
            HStack(spacing:0) {Color.red;Color.green;Color.blue}.frame(height:140)
            Text(CGPreflightScreenCaptureAccess() ? "Screen capture permission: granted" : "Screen capture permission: required")
            HStack {
                Button("Capture target / select region") {
                    guard task == nil else{return};attempts+=1;result="Waiting for selection"
                    task=Task { @MainActor in
                        defer{task=nil;writeProbe()}
                        do {result=try await workspace.captureAndWait(after:[.pin]) ? "Captured" : "Cancelled without image"}
                        catch {result=error.localizedDescription}
                    }
                }.disabled(task != nil || workspace.captureBusy)
                Button("Cancel pending capture"){task?.cancel()}.disabled(task == nil)
            }
            Text(result).textSelection(.enabled)
            Text("Pins: \(workspace.pinSession.count)")
        }.padding(24)
            .onReceive(clock){_ in writeProbe()}
            .onDisappear{task?.cancel();workspace.shutdown()}
    }
    private func writeProbe() {
        let record:[String:Any] = ["permissionGranted":CGPreflightScreenCaptureAccess(),"busy":workspace.captureBusy,"capturing":workspace.capturing,"result":result,"attempts":attempts,"pins":workspace.pinSession.count,"savedSnapshots":workspace.pinSession.library.pins.map(\.snapshotID.uuidString)]
        if let data=try? JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:root.appendingPathComponent("screenshot-probe.json"),options:.atomic)}
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

private struct CaptureSavingQA:View {
    let workspace:CaptureWorkspace
    let image:CGImage
    let root:URL
    @State private var running=false
    @State private var result=""
    var body:some View {
        VStack {
            CaptureSaveSettingsView(model:workspace.saving)
            HStack {
                Button("Run synthetic screenshot chain") {
                    running=true
                    Task { @MainActor in
                        let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally();running=false}
                        do {
                            let success=await workspace.processCaptured(image,options:try workspace.saving.snapshot(),pasteboard:board)
                            let record:[String:Any]=["success":success,"completed":workspace.saving.completed,"saved":workspace.saving.saved.map(\.path),"pins":workspace.pinSession.count,"clipboardText":board.string(forType:.string) ?? "","clipboardPNGBytes":board.data(forType:.png)?.count ?? 0,"issue":workspace.saving.issue ?? "none"]
                            try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("chain-result.json"),options:.atomic)
                            result=success ? "Chain succeeded" : "Chain failed"
                        } catch {result=error.localizedDescription}
                    }
                }.disabled(running)
                Text(result)
            }.padding(8)
        }
    }
}
