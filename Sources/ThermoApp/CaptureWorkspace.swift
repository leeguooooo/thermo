import AppKit
import CaptureCore
import CaptureScriptCore
import Carbon
import SwiftUI
import ThermoL10n
import UniformTypeIdentifiers

func captureFailureMessage(_ error:Error) -> String {
    if case CaptureWordFailure.unsupported(let item)=error { return String(format:tr("Word math export does not support: %@"),item) }
    if case CaptureMathFailure.invalidFormula(let reason)=error { return String(format:tr("Formula could not be rendered: %@"),reason) }
    return tr(error.localizedDescription)
}

@MainActor final class CaptureWorkspace: ObservableObject {
    static let shared = CaptureWorkspace()
    @Published var issue: String?
    @Published var capturing = false
    @Published var pinCount = 0
    let pinSession:CapturePinSession
    private let screenCaptureAccess:()->Bool
    private let makeCaptureProcess:(URL)->Process
    init(pinSession:CapturePinSession? = nil,
         screenCaptureAccess:@escaping()->Bool={CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()},
         makeCaptureProcess:@escaping(URL)->Process={output in
             let task=Process();task.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture")
             task.arguments=["-i","-x","-t","png",output.path]
             task.standardOutput=FileHandle.nullDevice;task.standardError=FileHandle.nullDevice
             return task
         }) {
        self.screenCaptureAccess=screenCaptureAccess;self.makeCaptureProcess=makeCaptureProcess
        self.pinSession=pinSession ?? CapturePinSession();self.pinSession.onCountChange={ [weak self] in self?.pinCount=$0 }
        self.pinSession.configureEditor={ [weak self] model in
            model.saveOptions={ [weak self] in try self?.saving.snapshot() ?? CaptureSaveSettings() }
            model.quickSaveImage={ [weak self] document in guard let self else {throw CaptureSaveFailure.invalidSettings};return try self.saving.quickSave(document) }
            model.showSaveSettings={ [weak self] in self?.showSavingSettings() }
        }
    }
    lazy var shortcuts=CaptureShortcutModel(backend:CaptureShortcutModel.backend(),read:{ UserDefaults.standard.data(forKey:CaptureShortcutModel.preferenceKey) },write:{ data in UserDefaults.standard.set(data,forKey:CaptureShortcutModel.preferenceKey) },pinFocused:{ [weak self] in self?.pinSession.focusedEditor() != nil },execute:{ [weak self] action in try self?.perform(action) }).withScriptExecutor(onIssue:{ [weak self] in self?.showActionSettings() }) { [weak self] source in guard let self else {throw CaptureScriptFailure.unavailable};return try await self.executeScript(source) }
    lazy var saving=CaptureSaveModel()
    private var savingWindow:NSWindowController?
    private var afterTask:Task<Void,Never>?
    private var actionsWindow:NSWindowController?
    private var activated=false
    private var shuttingDown=false
    private var process: Process?
    private var captureDirectory: URL?
    private var captureID:UUID?
    var captureBusy:Bool {capturing || process != nil || afterTask != nil || saving.running}
    private var captureCompletion:((Result<Bool,Error>)->Void)?
    @Published var scriptRunning=false
    var scriptWorker:URL?
    var scriptPasteboard:NSPasteboard?
    private var regionSelector: CaptureRegionSelector?
    private var scrollWindow: NSWindowController?
    private var recordingWindow: CaptureRecordingWindow?
    func activate() {
        guard !activated else { return };activated=true;shuttingDown=false
        pinSession.restoreWindows();shortcuts.activate()
    }
    func shortcutSuffix(for action:CaptureAction) -> String { let value=shortcuts.label(for:action);return value.isEmpty ? "" : "  "+value }
    func showActionSettings(model:CaptureShortcutModel? = nil) {
        let selectedModel=model ?? shortcuts;selectedModel.activate()
        if actionsWindow == nil {
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:940,height:620),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            window.title=tr("Capture shortcuts and actions");window.isReleasedWhenClosed=false;window.minSize=NSSize(width:780,height:520)
            window.contentView=NSHostingView(rootView:CaptureActionSettingsView(model:selectedModel));window.center();actionsWindow=NSWindowController(window:window)
        }
        actionsWindow?.showWindow(nil);NSApp.activate(ignoringOtherApps:true);actionsWindow?.window?.makeKeyAndOrderFront(nil)
    }
    func showSavingSettings() {
        if savingWindow == nil {
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:820,height:760),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            window.title=tr("Capture saving and after-actions");window.isReleasedWhenClosed=false
            window.contentView=NSHostingView(rootView:CaptureSaveSettingsView(model:saving));window.center();savingWindow=NSWindowController(window:window)
        }
        savingWindow?.showWindow(nil);NSApp.activate(ignoringOtherApps:true);savingWindow?.window?.makeKeyAndOrderFront(nil)
    }
    func shutdown() {
        pinSession.batchExport.cancel()
        shuttingDown=true;if let id=captureID{cancelCapture(id:id)};afterTask?.cancel();afterTask=nil
        if process?.isRunning == true {process?.terminate()}
        if let captureDirectory { try? FileManager.default.removeItem(at:captureDirectory) }; captureDirectory = nil
        regionSelector?.cancel(); regionSelector = nil
        scrollWindow?.close()
        shortcuts.shutdown();activated=false
    }
    func capture(after override:[CaptureAfterStep]?=nil,id:UUID=UUID(),completion:((Result<Bool,Error>)->Void)?=nil) {
        guard !captureBusy else {completion?(.failure(CaptureSaveFailure.busy));return}
        var options:CaptureSaveSettings
        do { options=try saving.snapshot();if let override {options.after=override};guard options.valid else {throw CaptureSaveFailure.invalidSettings} }
        catch { if let completion{completion(.failure(error))} else {saving.issue=captureFailureMessage(error);showSavingSettings()};return }
        guard screenCaptureAccess() else {if let completion{completion(.failure(CaptureFailure.captureFailed))} else {report(CaptureFailure.captureFailed)};return}
        issue = nil; capturing = true;captureID=id;captureCompletion=completion
        // The native selector supports region, Space for window, and Escape to cancel.
        // A unique private directory prevents cancelled captures from reusing old pixels.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-capture-" + UUID().uuidString, isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { failCapture(error);return }
        let output = directory.appendingPathComponent("capture.png")
        captureDirectory = directory
        let task=makeCaptureProcess(output)
        let pipelineOptions=options
        task.terminationHandler = { [weak self] task in
            Task { @MainActor in
                defer { try? FileManager.default.removeItem(at: directory) }
                guard let self else{return}
                // Cancellation completes promptly, but the selector still owns its slot until it exits.
                if self.process === task {self.process=nil}
                if self.captureDirectory == directory {self.captureDirectory=nil}
                guard self.captureID == id else {return}
                guard !self.shuttingDown else {self.finishCapture(.failure(CaptureScriptFailure.cancelled));return}
                self.process = nil
                self.captureDirectory = nil
                // Escape produces no file; leave clipboard and existing pins alone.
                guard FileManager.default.fileExists(atPath: output.path) else { self.finishCapture(.success(false));return }
                guard task.terminationStatus == 0 else { self.failCapture(CaptureFailure.captureFailed);return }
                do {
                    let image=try CaptureDocument.load(output)
                    self.afterTask=Task { @MainActor [weak self] in
                        guard let self else{return};defer{if self.captureID == nil || self.captureID == id{self.afterTask=nil}}
                        let success=await self.processCaptured(image,options:pipelineOptions)
                        guard self.captureID == id else{return}
                        let scripted=self.captureCompletion != nil
                        if Task.isCancelled {self.finishCapture(.failure(CaptureScriptFailure.cancelled))}
                        else if success {self.finishCapture(.success(true))}
                        else {self.finishCapture(.failure(CaptureScriptFailure.execution(self.saving.issue ?? "Capture failed.")));if !scripted{self.showSavingSettings()}}
                    }
                } catch {self.failCapture(error)}
            }
        }
        do { process = task; try task.run() }
        catch {process=nil;captureDirectory=nil;try? FileManager.default.removeItem(at:directory);failCapture(error)}
    }
    private func finishCapture(_ result:Result<Bool,Error>) {
        let completion=captureCompletion;captureCompletion=nil;captureID=nil;capturing=false;completion?(result)
    }
    private func failCapture(_ error:Error) {let scripted=captureCompletion != nil;finishCapture(.failure(error));if !scripted{report(error)}}
    func captureAndWait(after steps:[CaptureAfterStep]?=nil) async throws -> Bool {
        let id=UUID();try Task.checkCancellation()
        return try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation {continuation in
                if Task.isCancelled{continuation.resume(throwing:CancellationError());return}
                capture(after:steps,id:id,completion:{continuation.resume(with:$0)})
                if Task.isCancelled {cancelCapture(id:id)}
            }
        },onCancel:{Task{@MainActor in self.cancelCapture(id:id)}})
    }
    private func cancelCapture(id:UUID) {
        guard captureID == id else{return}
        if process?.isRunning == true{process?.terminate()}
        afterTask?.cancel()
        finishCapture(.failure(CaptureScriptFailure.cancelled))
    }
    @discardableResult func processCaptured(_ image:CGImage,options:CaptureSaveSettings,pasteboard:NSPasteboard = .general) async -> Bool {
        await saving.run(image,settings:options,pin:{ [weak self] in guard let self else {throw CaptureFailure.captureFailed};try self.pinSession.open($0) },copyImage:{ data in
            pasteboard.clearContents();guard pasteboard.setData(data,forType:.png) else {throw CaptureFailure.exportFailed}
        },copyText:{ text in
            pasteboard.clearContents();guard pasteboard.setString(text,forType:.string) else {throw CaptureFailure.exportFailed}
        })
    }
    func importImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do { open(try CaptureDocument.load(url)) } catch { report(error) }
        }
    }
    func captureScrolling() {
        guard regionSelector == nil else { return }
        if #available(macOS 14, *) {
            if let scrollWindow, scrollWindow.window?.isVisible == true { scrollWindow.showWindow(nil); return }
            let selector = CaptureRegionSelector(); regionSelector = selector
            selector.select { [weak self] region in
                guard let self else { return }; self.regionSelector = nil
                guard let region else { return }
                let window = ScrollCaptureWindow(region: region); self.scrollWindow = window; window.showWindow(nil)
            }
        } else { issue = tr("Scrolling capture requires macOS 14 or later."); showIssue() }
    }
    func recordScreen(draftsOnly: Bool = false) {
        if let recordingWindow, recordingWindow.model.active || recordingWindow.model.exporting {
            recordingWindow.showWindow(nil); return
        }
        recordingWindow?.close()
        if draftsOnly {
            let window = CaptureRecordingWindow(region:nil); recordingWindow = window; window.showWindow(nil); return
        }
        guard regionSelector == nil else { return }
        let selector = CaptureRegionSelector(); regionSelector = selector
        selector.select { [weak self] region in
            guard let self else { return }; self.regionSelector = nil
            guard let region else { return }
            let window = CaptureRecordingWindow(region:region); self.recordingWindow = window; window.showWindow(nil)
        }
    }
    var recordingActive: Bool { recordingWindow?.model.active == true || recordingWindow?.model.exporting == true }
    func terminationReply(_ previous:NSApplication.TerminateReply) -> NSApplication.TerminateReply {
        guard previous == .terminateNow else { return previous }
        if pinSession.batchExport.running {
            pinSession.batchExport.noteQuitBlocked();pinSession.showLibrary();return .terminateCancel
        }
        if afterTask != nil || saving.running {
            saving.issue=tr("Wait for the capture action chain to finish before quitting.");showSavingSettings();return .terminateCancel
        }
        do { try pinSession.flush() } catch { report(error);return .terminateCancel }
        guard recordingActive else { return previous }
        Task { NSApp.reply(toApplicationShouldTerminate:await finishRecordingForQuit()) }
        return .terminateLater
    }
    func finishRecordingForQuit() async -> Bool {
        guard let model = recordingWindow?.model else { return true }
        if model.exporting { recordingWindow?.showWindow(nil); return false }
        await model.stop()
        if model.phase == .failed { recordingWindow?.showWindow(nil); return false }
        return !model.active
    }
    func pinClipboard(asText:Bool=false,asLaTeX:Bool=false) {
        do { switch try CapturePinClipboard.read(.general,asText:asText,asLaTeX:asLaTeX) {
            case .image(let image):try pinSession.open(image)
            case .content(let content):try pinSession.open(content)
        } } catch { report(error) }
    }
    func open(_ image: CGImage) {
        do { try pinSession.open(image) } catch { report(error) }
    }
    func showPinLibrary() { pinSession.showLibrary() }
    func restoreLastPin() { do { try pinSession.restore() } catch { report(error) } }
    func showAll() { do { try pinSession.setAllHidden(false) } catch { report(error) } }
    func hideAll() { do { try pinSession.setAllHidden(true) } catch { report(error) } }
    func closeAll() { pinSession.closeAll() }
    func perform(_ action:CaptureAction) throws {
        switch action {
        case .script:throw CaptureScriptFailure.execution("Run a configured script entry with its source.")
        case .restoreMouseInteraction:pinSession.restoreMouseInteraction()
        case .togglePassthrough:
            guard let editor=pinSession.editorUnderMouse() ?? pinSession.activeEditor() else {throw CaptureActionFailure.noPin}
            editor.model.mousePassthrough.toggle()
        case .screenshot:capture()
        case .screenshotCopy:capture(after:[.copyImage])
        case .screenshotOCR:capture(after:[.copyText])
        case .screenshotQuickSave:capture(after:[.quickSave])
        case .saveSettings:showSavingSettings()
        case .pinClipboard:pinClipboard()
        case .pinText:pinClipboard(asText:true)
        case .pinLaTeX:pinClipboard(asLaTeX:true)
        case .openImage:importImage()
        case .scrolling:captureScrolling()
        case .recording:recordScreen()
        case .recordingDrafts:recordScreen(draftsOnly:true)
        case .pinGroups:showPinLibrary()
        case .shortcutSettings:showActionSettings()
        case .nextGroup,.previousGroup:
            guard let index=pinSession.library.groups.firstIndex(where:{ $0.id == pinSession.library.currentGroupID }) else { throw CapturePinFailure.invalidLibrary }
            let groups=pinSession.library.groups,next=(index+(action == .nextGroup ? 1 : groups.count-1))%groups.count
            try pinSession.switchGroup(groups[next].id)
        case .restorePin:try pinSession.restore()
        case .showPins:try pinSession.setAllHidden(false)
        case .hidePins:try pinSession.setAllHidden(true)
        case .togglePins:
            let visible=pinSession.library.pins.contains { $0.groupID == pinSession.library.currentGroupID && $0.closedAt == nil && !$0.hidden }
            try pinSession.setAllHidden(visible)
        case .closePins:pinSession.closeAll()
        default:
            guard let editor=pinSession.activeEditor(includeHidden:action == .showPin) else { throw CaptureActionFailure.noPin }
            let model=editor.model
            guard !action.imageOnly || model.pinContent == nil else { throw CaptureActionFailure.imageRequired }
            if action.requiresUnlockedPin {try model.requireEditable()}
            switch action {
            case .showPin:if let id=pinSession.windows.first(where:{ $0.value === editor })?.key { try pinSession.showPin(id) }
            case .closePin:editor.window?.performClose(nil)
            case .copyImage:model.copy()
            case .copyContent:if let content=model.pinContent { try CapturePinClipboard.copy(content,to:.general) } else { model.copy() }
            case .saveImage:model.save()
            case .quickSaveImage:try model.quickSave()
            case .recognize:model.recognize();editor.showWindow(nil)
            case .toggleTop:model.pinned.toggle();model.changeWindow?()
            case .toggleLock:model.locked.toggle();model.changeWindow?()
            case .resetZoom:model.zoom=1;model.pan = .zero
            case .grayscale,.invert,.brightnessUp,.brightnessDown,.resetImageAdjustments:try model.applyColorAction(action)
            case .rotateLeft:try model.transformImage(.rotateCounterclockwise)
            case .flipVertical:try model.transformImage(.flipVertical)
            case .rotate:try model.transformImage(rotateClockwise:true)
            case .flip:try model.transformImage(flipHorizontal:true)
            case .undo:model.undoAnnotation()
            case .redo:model.redoAnnotation()
            default:break
            }
        }
    }
    func report(_ error: Error) { issue = captureFailureMessage(error); showIssue() }
    private func showIssue() {
        let alert = NSAlert(); alert.messageText = tr("Screenshots and pins"); alert.informativeText = issue ?? ""; alert.runModal()
    }
}

@MainActor final class CaptureEditorModel: ObservableObject {
    @Published var document: CaptureDocument { didSet {
        revision += 1; cropSelection=nil; recognition = "";onMutation?(true)
        selectedAnnotations=selectedAnnotations.filter {document.annotations.indices.contains($0)}
    } }
    private(set) var revision = 0
    @Published var tool: CaptureTool = .move {didSet {if tool != .crop {cropSelection=nil}}}
    @Published var cropSelection:CGRect?
    @Published private(set) var selectedAnnotations:Set<Int> = []
    var selectedAnnotation:Int? {
        get {selectedAnnotations.count == 1 ? selectedAnnotations.first : nil}
        set {selectAnnotations(newValue.map{[$0]} ?? [])}
    }
    func selectAnnotations(_ indices:Set<Int>) {
        selectedAnnotations=indices.filter{document.annotations.indices.contains($0)}
        if let index=selectedAnnotation {
            let item=document.annotations[index];color=Color(nsColor:item.color);lineWidth=item.width;text=item.text;annotationOptions=item.options
        }
    }
    func selectAllAnnotations() {guard !locked else{return};selectingOCRText=false;tool = .select;selectAnnotations(Set(document.annotations.indices))}
    @Published var connectedLine=false
    @Published var nextSequenceNumber=1
    func chooseTool(_ tool:CaptureTool) {
        selectingOCRText=false;selectAnnotations([])
        if tool == .number,self.tool != .number {
            annotationOptions.numberLeader=true
            nextSequenceNumber=max(nextSequenceNumber,(document.annotations.filter{$0.tool == .number}.compactMap{$0.options.numberValue ?? Int($0.text)}.filter{(1...3999).contains($0)}.max() ?? 0)+1)
        }
        self.tool=tool
    }
    @Published var arrowCommentEditingID=UUID()
    @Published var annotationOptions=CaptureAnnotationOptions()
    @Published var color = Color.red
    @Published var lineWidth: Double = 4
    @Published var text = ""
    @Published var recognition = "" {didSet {if oldValue != recognition {ocrSegments=[];selectedOCRSegments=[];selectingOCRText=false}}}
    @Published var ocrSegments:[CaptureTextSegment]=[]
    var copyPasteboard:NSPasteboard?
    @Published var selectedOCRSegments:Set<Int>=[]
    @Published var selectingOCRText=false {didSet {selectedOCRSegments=[];if selectingOCRText {cropSelection=nil;selectAnnotations([])}}}
    @Published var recognizing = false
    @Published var pinContent:CapturePinContent?
    var makeImageCopy:((CGImage)->Void)?
    var snapshotPinContent:(() async throws -> CGImage)?
    @Published var pinContentSaveError:String?
    @Published var pinTextReloadID=UUID()
    func revertUnsavedPinText() { pinContentSaveError=nil;error=nil;pinTextReloadID=UUID() }
    func updatePinContent(_ content:CapturePinContent,derivedHTMLText:Bool=false) throws {
        if locked {
            // Loading an unchanged HTML pin may fill its initially empty, derived plain text.
            // No source, formatting or other content change is allowed through this path.
            guard derivedHTMLText,case .text(let previous)=pinContent,case .text(let next)=content,
                  previous.usesHTML,previous.plain.isEmpty,!next.plain.isEmpty,next.plain.utf8.count<=1024*1024 else {throw CaptureActionFailure.pinLocked}
            var expected=previous;expected.plain=next.plain
            guard expected == next else {throw CaptureActionFailure.pinLocked}
        }
        do {
            let image=try content.previewImage()
            pinContentSaveError=nil;pinContent=content;document=CaptureDocument(image:image)
        } catch { pinContentSaveError=captureFailureMessage(error);throw error }
    }
    var onMutation:((Bool)->Void)?
    var showPinLibrary:(() -> Void)?
    @Published var pinTitle="" { didSet { changeWindow?();onMutation?(false) } }
    @Published var locked=false { didSet { if locked {cropSelection=nil};changeWindow?();onMutation?(false) } }
    /// Interaction is temporary, never stored in a pin snapshot or restored after reopening.
    @Published var mousePassthrough=false {didSet {interactionWindow?();onInteractionChange?()}}
    var interactionWindow:(()->Void)?
    var onInteractionChange:(()->Void)?
    @Published var shadow=true { didSet { changeWindow?();onMutation?(false) } }
    @Published var pan=CGPoint.zero { didSet { onMutation?(false) } }
    @Published var opacity: Double = 1 { didSet { onMutation?(false) } }
    @Published var pinned = true { didSet { onMutation?(false) } }
    @Published var error: String?
    @Published var zoom: Double = 1 { didSet { onMutation?(false) } }
    var changeWindow: (() -> Void)?
    init(image: CGImage) { document = CaptureDocument(image: image) }
    func selectAnnotation(_ index:Int?) {
        if index != nil {selectingOCRText=false}
        selectedAnnotation=index
    }
    func applySelectedStyle() {
        guard !locked,let index=selectedAnnotation,document.annotations.indices.contains(index) else { return }
        var item=document.annotations[index]
        let nextColor=NSColor(color)
        guard item.color != nextColor || item.width != lineWidth || item.text != text || item.options != annotationOptions else { return }
        item.color=nextColor;item.width=lineWidth;item.text=text;item.options=annotationOptions
        document.replaceAnnotation(at:index,with:item)
    }
    func requireEditable() throws {guard !locked else {throw CaptureActionFailure.pinLocked}}
    func transformImage(_ operation:CaptureImageTransform) throws {
        try requireEditable();guard pinContent==nil else {throw CaptureActionFailure.imageRequired}
        try document.transform(operation)
    }
    func transformImage(rotateClockwise:Bool=false,flipHorizontal:Bool=false) throws {
        try requireEditable();guard pinContent==nil else {throw CaptureActionFailure.imageRequired};try document.transform(rotateClockwise:rotateClockwise,flipHorizontal:flipHorizontal)
    }
    func undoAnnotation() { guard !locked else{return};document.undo();if let selectedAnnotation {selectAnnotation(selectedAnnotation)} }
    func redoAnnotation() { guard !locked else{return};document.redo();if let selectedAnnotation {selectAnnotation(selectedAnnotation)} }
    func deleteSelected() {
        guard !locked else{return}
        document.removeAnnotations(at:selectedAnnotations);selectedAnnotations=[]
    }
    var imageDisplayScale:(()->CGFloat?)?
    func displayedDocument() throws -> CaptureDocument {
        guard let scale=imageDisplayScale?() else {throw CaptureImageExportFailure.viewUnavailable}
        return try CaptureImageExport.displayed(document,scale:scale,opacity:opacity)
    }
    func copyDisplayedImage() {
        do {copyDocument(try displayedDocument())} catch {self.error=tr(error.localizedDescription)}
    }
    func copy() {copyDocument(document)}
    func copyDocument(_ output:CaptureDocument) {
        do {
            let data = try output.data()
            let board=copyPasteboard ?? .general
            board.clearContents();board.setData(data,forType:.png)
        } catch { self.error = tr(error.localizedDescription) }
    }
    var saveOptions:(()throws->CaptureSaveSettings)?
    var quickSaveImage:((CaptureDocument)throws->URL)?
    var showSaveSettings:(()->Void)?
    @Published var savedImagePath:String?
    func quickSave() throws {
        guard let quickSaveImage else {throw CaptureSaveFailure.missingDirectory}
        savedImagePath=try quickSaveImage(document).path;error=nil
    }
    func save(displayed:Bool=false) {
        let options:CaptureSaveSettings,output:CaptureDocument
        do {
            options=try saveOptions?() ?? CaptureSaveSettings()
            output=displayed ? try displayedDocument() : document
        } catch {self.error=captureFailureMessage(error);return}
        let panel = NSSavePanel(),manual=CaptureManualImageSave()
        manual.configure(panel,name:(displayed ? "Thermo-display-" : "Thermo-") + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"))
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try manual.save(output,to:url,quality:options.quality)
            savedImagePath=url.path;error=nil
            if options.copyAfterManualSave {copyDocument(output)}
        } catch { self.error = tr(error.localizedDescription) }
    }
    func recognizeForScript() async throws -> String {
        guard !recognizing else {throw CaptureSaveFailure.busy}
        let image=try document.rendered(),initial=revision;recognizing=true;defer{recognizing=false}
        let result=try await Task.detached(priority:.userInitiated){try CaptureRecognition.recognize(image)}.value
        try Task.checkCancellation();guard initial == revision else {throw CaptureScriptFailure.execution("The image changed. Run recognition again.")}
        let value=([result.text]+result.codes).filter{!$0.isEmpty}.joined(separator:"\n");guard !value.isEmpty else {throw CaptureSaveFailure.noText};recognition=value;error=nil;return value
    }
    func recognize() {
        guard !recognizing else { return }
        do {
            let image = try document.rendered()
            let revision = self.revision
            recognizing = true; error = nil
            Task {
                do {
                    let result = try await Task.detached(priority: .userInitiated) { try CaptureRecognition.recognize(image,includeGeometry:true) }.value
                    if self.revision == revision {
                        recognition = ([result.text] + result.codes).filter { !$0.isEmpty }.joined(separator: "\n")
                        ocrSegments=result.segments;selectedOCRSegments=[];selectingOCRText=false
                        if recognition.isEmpty { error = tr("No text or barcode found.") }
                    } else { error = tr("The image changed. Run recognition again.") }
                } catch { self.error = tr(error.localizedDescription) }
                recognizing = false
            }
        } catch { self.error = tr(error.localizedDescription) }
    }
}

@MainActor final class CaptureEditor: NSWindowController, NSWindowDelegate {
    let model: CaptureEditorModel
    private let onClose: () -> Void
    private let shouldClose:(() -> Bool)?
    var onWindowChange:(() -> Void)?
    var onActivate:(() -> Void)?
    init(image: CGImage, onClose: @escaping () -> Void,shouldClose:(() -> Bool)? = nil) {
        model = CaptureEditorModel(image: image); self.onClose = onClose;self.shouldClose=shouldClose
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 650), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = tr("Screenshots and pins"); window.isReleasedWhenClosed = false
        window.level = .floating; window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.minSize = NSSize(width: 600, height: 360); window.center()
        super.init(window: window); window.delegate = self
        model.changeWindow = { [weak self] in
            guard let self, let window = self.window else { return }
            window.alphaValue = self.model.opacity; window.level = self.model.pinned ? .floating : .normal
            self.applyMouseInteraction()
            window.hasShadow=self.model.shadow;window.isMovable = !self.model.locked
            window.styleMask=self.model.locked ? [.titled,.closable,.miniaturizable] : [.titled,.closable,.miniaturizable,.resizable]
        }
        model.interactionWindow={ [weak self] in self?.applyMouseInteraction() }
        window.contentView = NSHostingView(rootView: CaptureEditorRoot(model:model))
    }
    private func applyMouseInteraction() {
        guard let window else {return}
        window.ignoresMouseEvents=model.mousePassthrough
        if model.mousePassthrough {window.makeFirstResponder(nil)}
        let title=model.pinTitle.isEmpty ? tr("Screenshots and pins") : model.pinTitle
        window.title=title+(model.mousePassthrough ? " · "+tr("Mouse passthrough") : "")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    func windowShouldClose(_ sender:NSWindow) -> Bool { shouldClose?() ?? true }
    func windowWillClose(_ notification: Notification) { onClose() }
    func windowDidBecomeKey(_ notification:Notification) { onActivate?() }
    func windowDidMove(_ notification:Notification) { onWindowChange?() }
    func windowDidResize(_ notification:Notification) { onWindowChange?() }
}

private struct CaptureEditorRoot:View {
    @ObservedObject var model:CaptureEditorModel
    var body:some View { Group { if model.pinContent != nil { CaptureTypedPinView(model:model) } else { CaptureEditorView(model:model) } } }
}

private struct CaptureEditorView: View {
    @ObservedObject var model: CaptureEditorModel
    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CaptureTool.allCases) { tool in
                        Button { model.chooseTool(tool) } label: { Image(systemName: tool.symbol).frame(width: 22, height: 24) }
                            .help(tr(tool.label)).accessibilityLabel(tr(tool.label))
                            .tint(model.tool == tool ? .accentColor : .secondary)
                            .background(model.tool == tool ? Color.accentColor.opacity(0.25) : Color.clear)
                            .cornerRadius(5).accessibilityValue(model.tool == tool ? tr("Selected") : "")
                    }
                    ColorPicker(tr("Annotation color"), selection: $model.color).labelsHidden()
                    Slider(value: $model.lineWidth, in: 1...12).frame(width: 65).help(tr("Line width"))
                    Button { model.undoAnnotation() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!model.document.canUndo).help(tr("Undo"))
                    Button { model.redoAnnotation() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!model.document.canRedo).help(tr("Redo"))
                    Button {
                        do { try model.transformImage(rotateClockwise:true) } catch { model.error = tr(error.localizedDescription) }
                    } label: { Image(systemName: "rotate.right") }.help(tr("Rotate clockwise")).accessibilityLabel(tr("Rotate clockwise"))
                    Button {
                        do {try model.transformImage(.rotateCounterclockwise)} catch {model.error=tr(error.localizedDescription)}
                    } label:{Image(systemName:"rotate.left")}.help(tr("Rotate counterclockwise")).accessibilityLabel(tr("Rotate counterclockwise"))
                    Button {
                        do { try model.transformImage(flipHorizontal:true) } catch { model.error = tr(error.localizedDescription) }
                    } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }.help(tr("Flip horizontally")).accessibilityLabel(tr("Flip horizontally"))
                    Button {
                        do {try model.transformImage(.flipVertical)} catch {model.error=tr(error.localizedDescription)}
                    } label:{Image(systemName:"arrow.up.and.down.righttriangle.up.righttriangle.down")}.help(tr("Flip vertically")).accessibilityLabel(tr("Flip vertically"))
                }.padding(8).disabled(model.locked)
            }
            HStack {
                TextField(tr("Pin title"),text:$model.pinTitle).textFieldStyle(.roundedBorder)
                Toggle(tr("Lock pin"),isOn:$model.locked)
                Toggle(tr("Mouse passthrough"),isOn:$model.mousePassthrough)
                    .help(tr("Temporary mode. Restore interaction from the capture menu or Pin groups and history."))
                Toggle(tr("Pin shadow"),isOn:$model.shadow)
                if let show=model.showPinLibrary { Button(tr("Pin groups and history"),action:show) }
            }.padding(.horizontal,10)
            CaptureImageAdjustmentControls(model:model).disabled(model.locked)
            CaptureAnnotationControls(model:model).disabled(model.locked)
            if model.tool == .crop {CaptureCropControls(model:model).disabled(model.locked)}
            if model.tool == .text || model.tool == .watermark {
                TextField(tr("Annotation text"), text: $model.text).textFieldStyle(.roundedBorder).padding(8).disabled(model.locked)
            }
            CaptureCanvas(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
            if !model.recognition.isEmpty {
                TextEditor(text: $model.recognition).font(.system(.body, design: .monospaced)).frame(height: 120).disabled(model.recognizing)
                HStack {
                    if !model.ocrSegments.isEmpty {Toggle(tr("Select text in image"),isOn:$model.selectingOCRText)}
                    Button(tr(model.selectedOCRSegments.isEmpty ? "Copy recognized text" : "Copy selected text")) {model.copyOCRText()}
                        .keyboardShortcut(model.selectingOCRText ? KeyboardShortcut("c",modifiers:.command) : nil)
                }.padding(4)
            }
            if let path=model.savedImagePath { Text(String(format:tr("Saved to %@"),path)).font(.caption).textSelection(.enabled) }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled).padding(6) }
            if model.recognizing { HStack { ProgressView().controlSize(.small); Text(tr("Recognizing text and barcodes…")) }.padding(6) }
            HStack {
                Toggle(tr("Keep on top"), isOn: $model.pinned).onChange(of: model.pinned) { _ in model.changeWindow?() }
                Slider(value: $model.opacity, in: 0.2...1).disabled(model.locked).frame(width: 80).help(tr("Pin opacity")).onChange(of: model.opacity) { _ in model.changeWindow?() }
                Slider(value: $model.zoom, in: 0.25...4).disabled(model.locked).frame(width: 70).help(tr("Zoom"))
                Text("\(model.document.image.width) × \(model.document.image.height)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(tr("Text / QR")) { model.recognize() }.disabled(model.recognizing)
                Button(tr("Copy image")) { model.copy() }.keyboardShortcut(model.selectingOCRText ? nil : KeyboardShortcut("c",modifiers:.command))
                Menu(tr("Saving options")) {
                    Button(tr("Copy full-resolution image")){model.copy()}
                    Button(tr("Copy displayed-size image")){model.copyDisplayedImage()}
                    Button(tr("Save full-resolution image…")){model.save()}
                    Button(tr("Save displayed-size image…")){model.save(displayed:true)}
                    Divider()
                    Button(tr("Quick save")) {do {try model.quickSave()} catch {model.error=captureFailureMessage(error)}}.keyboardShortcut("s",modifiers:[.command,.shift])
                    Button(tr("Capture saving and after-actions")){model.showSaveSettings?()}
                }
                Button(tr("Save image…")) { model.save() }.keyboardShortcut("s", modifiers: .command)
            }.padding(10)
        }
    }
}

extension CaptureTool {
    var label: String {
        switch self {
        case .move: return "Move / view";case .select:return "Select annotation"; case .rectangle: return "Rectangle"; case .ellipse: return "Ellipse"
        case .line: return "Line"; case .arrow: return "Arrow"; case .pencil: return "Pencil"
        case .highlight: return "Highlighter"; case .redact: return "Opaque redaction"; case .text: return "Text"
        case .mosaic:return "Mosaic";case .blur:return "Blur";case .eraser:return "Brush eraser";case .eraserRect:return "Rectangle eraser";case .spotlight:return "Spotlight";case .magnifier:return "Magnifier";case .watermark:return "Tiled watermark";case .number: return "Sequence number"; case .crop: return "Crop (flattens annotations)"
        }
    }
    var symbol: String {
        switch self {
        case .move: return "hand.draw";case .select:return "cursorarrow"; case .rectangle: return "rectangle"; case .ellipse: return "circle"
        case .line: return "line.diagonal"; case .arrow: return "arrow.up.right"; case .pencil: return "pencil.tip"
        case .highlight: return "highlighter"; case .redact: return "square.fill"; case .text: return "textformat"
        case .mosaic:return "square.grid.3x3.fill";case .blur:return "drop.halffull";case .eraser:return "eraser";case .eraserRect:return "eraser.fill";case .spotlight:return "light.beacon.max";case .magnifier:return "plus.magnifyingglass";case .watermark:return "text.badge.checkmark";case .number: return "1.circle"; case .crop: return "crop"
        }
    }
}

struct CaptureCanvas: NSViewRepresentable {
    @ObservedObject var model: CaptureEditorModel
    func makeNSView(context: Context) -> Canvas { Canvas(model: model) }
    func updateNSView(_ view: Canvas, context: Context) { view.model = model;view.reconcileConnectedLine();view.updateOCRAccessibility();view.needsDisplay = true }
    final class Canvas: NSView {
        var model: CaptureEditorModel {didSet {if oldValue !== model {renderCache.remove(owner:cacheOwner);bindExportGeometry()}}}
        private let renderCache:CaptureRenderCache
        private let cacheOwner=UUID()
        private let render:(CaptureDocument,CaptureAnnotation?,[Int:CaptureAnnotation])throws->CGImage
        private var windowObservers:[NSObjectProtocol]=[]
        var draft: CaptureAnnotation?
        var connectedLineVertices:[CGPoint]=[]
        var connectedLineRevision:Int?
        var connectedLineOwner:ObjectIdentifier?
        var connectedLineTracking:NSTrackingArea?
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let connectedLineTracking {removeTrackingArea(connectedLineTracking)}
            let area=NSTrackingArea(rect:.zero,options:[.mouseMoved,.activeInKeyWindow,.inVisibleRect,.enabledDuringMouseDrag],owner:self,userInfo:nil)
            addTrackingArea(area);connectedLineTracking=area
        }
        override func mouseMoved(with event:NSEvent) {if !updateConnectedLinePreview(event) {super.mouseMoved(with:event)}}
        override func rightMouseDown(with event:NSEvent) {
            reconcileConnectedLine()
            if !connectedLineVertices.isEmpty {finishConnectedLine();return}
            super.rightMouseDown(with:event)
        }
        var cropDragStart:CGPoint?
        var cropDragOriginal:CGRect?
        var cropResizing=false
        var cropGestureRevision:Int?
        var pan:CGPoint { get { model.pan } set { model.pan=newValue } }
        var lastDrag: CGPoint?
        var selectionStart:CGPoint?
        var selectionOriginal:[Int:CaptureAnnotation]=[:]
        var selectionPreview:[Int:CaptureAnnotation]=[:]
        var selectionBounds:CGRect?
        var selectionRevision:Int?
        var selectionMoved=false
        var marqueeStart:CGPoint?
        var marqueeRect:CGRect?
        var marqueeBaseline:Set<Int>=[]
        var resizing=false
        var endpointIndex:Int?
        var ocrDragStart:CGPoint?
        var ocrBaseline:Set<Int>=[]
        var ocrAccessibilityElements:[CaptureOCRAccessibilityElement]=[]
        var ocrAccessibilitySnapshot:[CaptureTextSegment]=[]
        var ocrAccessibilityText=""
        override func isAccessibilityElement() -> Bool {model.selectingOCRText}
        override func accessibilityRole() -> NSAccessibility.Role? {.group}
        override func accessibilityLabel() -> String? {tr("Recognized text regions")}
        override func accessibilityChildren() -> [Any]? {
            updateOCRAccessibility();return ocrAccessibilityElements
        }
        func updateOCRAccessibility() {
            guard model.selectingOCRText else {ocrAccessibilityElements=[];ocrAccessibilitySnapshot=[];ocrAccessibilityText="";return}
            if ocrAccessibilitySnapshot != model.ocrSegments || ocrAccessibilityText != model.recognition {
                ocrAccessibilitySnapshot=model.ocrSegments;ocrAccessibilityText=model.recognition
                ocrAccessibilityElements=model.ocrSegments.indices.compactMap {index in
                    let item=model.ocrSegments[index]
                    guard let range=Range(item.range,in:model.recognition) else {return nil}
                    return CaptureOCRAccessibilityElement(canvas:self,index:index,segment:item,label:String(model.recognition[range]))
                }
            }
            for item in ocrAccessibilityElements {
                let rect=model.ocrRect(item.index),s=scale
                let local=CGRect(x:imageRect.minX+rect.minX*s,y:imageRect.minY+rect.minY*s,width:rect.width*s,height:rect.height*s).intersection(bounds)
                item.setAccessibilityFrame(NSAccessibility.screenRect(fromView:self,rect:local.isNull ? .zero : local))
                item.setAccessibilityValue(NSNumber(value:model.selectedOCRSegments.contains(item.index)))
            }
        }
        init(model:CaptureEditorModel,cache:CaptureRenderCache = .shared,
             render:@escaping(CaptureDocument,CaptureAnnotation?,[Int:CaptureAnnotation])throws->CGImage={try $0.rendered(adding:$1,replacements:$2)}) {
            self.model=model;self.renderCache=cache;self.render=render;super.init(frame:.zero);bindExportGeometry()
        }
        deinit {
            for observer in windowObservers {NotificationCenter.default.removeObserver(observer)}
            renderCache.remove(owner:cacheOwner)
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow();renderCache.remove(owner:cacheOwner)
            for observer in windowObservers {NotificationCenter.default.removeObserver(observer)};windowObservers=[]
            guard let window else {return}
            window.acceptsMouseMovedEvents=true
            for name in [NSWindow.didChangeOcclusionStateNotification,NSWindow.willCloseNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(forName:name,object:window,queue:.main) { [weak self] note in
                    MainActor.assumeIsolated {
                        guard let self else{return}
                        if note.name == NSWindow.willCloseNotification || self.window?.isVisible != true || self.window?.occlusionState.contains(.visible) != true {
                            self.renderCache.remove(owner:self.cacheOwner)
                        }
                    }
                })
            }
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance();renderCache.remove(owner:cacheOwner);needsDisplay=true
        }
        func renderedImage() throws -> CGImage {
            reconcileConnectedLine()
            let preview=draft?.tool == .crop ? nil : draft
            let replacements=model.tool == .select && !model.locked && selectionRevision == model.revision ? selectionPreview : [:]
            if preview != nil || !replacements.isEmpty {return try render(model.document,preview,replacements)}
            return try renderCache.image(owner:cacheOwner,source:ObjectIdentifier(model),revision:model.revision) {try render(model.document,nil,[:])}
        }
        func bindExportGeometry() {
            model.imageDisplayScale={ [weak self,weak source=model] in
                guard let self,let source,self.model === source,self.scale.isFinite,self.scale>0 else{return nil}
                return self.scale
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        override var acceptsFirstResponder: Bool { true }
        var scale: CGFloat { min(bounds.width/model.document.size.width, bounds.height/model.document.size.height)*model.zoom }
        var imageRect: CGRect {
            let s = model.document.size; return CGRect(x: (bounds.width-s.width*scale)/2+pan.x, y: (bounds.height-s.height*scale)/2+pan.y, width: s.width*scale, height: s.height*scale)
        }
        func point(_ event: NSEvent) -> CGPoint {
            let p = convert(event.locationInWindow, from: nil), rect = imageRect
            return CGPoint(x: min(model.document.size.width, max(0, (p.x-rect.minX)/scale)), y: min(model.document.size.height, max(0, (p.y-rect.minY)/scale)))
        }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.windowBackgroundColor.setFill(); bounds.fill()
            guard scale > 0, let ctx = NSGraphicsContext.current?.cgContext else { return }
            ctx.saveGState();ctx.clip(to:bounds)
            ctx.translateBy(x: imageRect.minX, y: imageRect.minY); ctx.scaleBy(x: scale, y: scale)
            do {
                let image=try renderedImage()
                ctx.draw(image,in:CGRect(origin:.zero,size:model.document.size))
            } catch {
                ctx.setFillColor(NSColor.black.cgColor);ctx.fill(CGRect(origin:.zero,size:model.document.size))
                let message=tr(error.localizedDescription)
                DispatchQueue.main.async { [weak model] in if model?.error != message { model?.error=message } }
            }
            let selected=model.selectedAnnotations.sorted().compactMap { index -> CaptureAnnotation? in
                guard model.document.annotations.indices.contains(index) else{return nil}
                return !model.locked && selectionRevision == model.revision ? selectionPreview[index] ?? model.document.annotations[index] : model.document.annotations[index]
            }
            if model.selectingOCRText {
                for index in model.ocrSegments.indices {
                    let rect=model.ocrRect(index)
                    if model.selectedOCRSegments.contains(index) {ctx.setFillColor(NSColor.selectedTextBackgroundColor.withAlphaComponent(0.35).cgColor);ctx.fill(rect)}
                    ctx.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.35).cgColor);ctx.setLineWidth(0.5/scale);ctx.stroke(rect)
                }
            }
            if let first=selected.first {
                let rect=selected.dropFirst().reduce(first.bounds){$0.union($1.bounds)}
                ctx.setStrokeColor(NSColor.systemBlue.cgColor);ctx.setLineWidth(1/scale);ctx.setLineDash(phase:0,lengths:[4/scale,3/scale]);ctx.stroke(rect);ctx.setLineDash(phase:0,lengths:[])
                if selected.count > 1 {for item in selected {ctx.stroke(item.bounds)}}
                ctx.setFillColor(NSColor.systemBlue.cgColor)
                if selected.count == 1,[CaptureTool.line,.arrow].contains(first.tool),let a=first.points.first,let b=first.points.last {
                    for p in (first.tool == .line ? first.points : [a,b]) {ctx.fillEllipse(in:CGRect(x:p.x-5/scale,y:p.y-5/scale,width:10/scale,height:10/scale))}
                } else {ctx.fill(CGRect(x:rect.maxX-4/scale,y:rect.maxY-4/scale,width:8/scale,height:8/scale))}
            }
            if let rect=marqueeRect {ctx.setFillColor(NSColor.systemBlue.withAlphaComponent(0.12).cgColor);ctx.fill(rect);ctx.setStrokeColor(NSColor.systemBlue.cgColor);ctx.setLineWidth(1/scale);ctx.stroke(rect)}
            if model.tool == .crop,let rect=model.cropSelection {
                ctx.setStrokeColor(NSColor.systemBlue.cgColor);ctx.setLineWidth(2/scale);ctx.stroke(rect)
                ctx.setFillColor(NSColor.systemBlue.cgColor);ctx.fill(CGRect(x:rect.maxX-4/scale,y:rect.maxY-4/scale,width:8/scale,height:8/scale))
            }
            if let draft {
                if draft.tool == .crop, let start = draft.points.first, let end = draft.points.last {
                    ctx.setStrokeColor(NSColor.systemBlue.cgColor); ctx.setLineWidth(2/scale)
                    ctx.stroke(CGRect(x: min(start.x,end.x), y: min(start.y,end.y), width: abs(end.x-start.x), height: abs(end.y-start.y)))
                }
            }
            ctx.restoreGState()
        }
        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            if handleConnectedLineClick(event) {return}
            cancelSelectionGesture();draft=nil;cropDragStart=nil;cropDragOriginal=nil;cropGestureRevision=model.revision
            ocrDragStart=nil;ocrBaseline=[]
            if model.selectingOCRText,scale > 0 {
                let p=point(event);ocrDragStart=p;ocrBaseline=event.modifierFlags.contains(.shift) ? model.selectedOCRSegments : []
                let hits=Set(model.ocrSegments.indices.filter{model.ocrRect($0).contains(p)})
                model.selectedOCRSegments=event.modifierFlags.contains(.shift) ? ocrBaseline.symmetricDifference(hits) : hits
                needsDisplay=true;return
            }
            if model.locked || scale <= 0 { return }
            if model.tool == .crop,let rect=model.cropSelection {
                let p=point(event)
                cropResizing=hypot(p.x-rect.maxX,p.y-rect.maxY) <= 10/scale
                if cropResizing || rect.contains(p) {
                    cropDragStart=p;cropDragOriginal=rect;return
                }
                model.cropSelection=nil
            }
            if model.tool == .select {
                guard imageRect.contains(convert(event.locationInWindow,from:nil)) else{return}
                let p=point(event)
                let additive=event.modifierFlags.contains(.shift)
                let items=model.selectedAnnotations.sorted().map{model.document.annotations[$0]}
                if !additive,event.clickCount == 2,let hit=model.document.hitTest(p,tolerance:5/scale),model.document.annotations[hit].tool == .arrow {
                    model.selectAnnotation(hit);model.arrowCommentEditingID=UUID();needsDisplay=true;return
                }
                if let first=items.first,!additive {
                    if items.count == 1,[CaptureTool.line,.arrow].contains(first.tool),first.points.count >= 2 {
                        let indices=first.tool == .line ? Array(first.points.indices) : [0,first.points.count-1]
                        endpointIndex=indices.min{hypot(p.x-first.points[$0].x,p.y-first.points[$0].y)<hypot(p.x-first.points[$1].x,p.y-first.points[$1].y)}
                        if let index=endpointIndex,hypot(p.x-first.points[index].x,p.y-first.points[index].y)>10/scale {endpointIndex=nil}
                    } else {
                        let bounds=items.dropFirst().reduce(first.bounds){$0.union($1.bounds)}
                        resizing=hypot(p.x-bounds.maxX,p.y-bounds.maxY) < 10/scale
                    }
                }
                if !resizing && endpointIndex == nil {
                    if let hit=model.document.hitTest(p,tolerance:5/scale) {
                        if additive {
                            var indices=model.selectedAnnotations
                            if indices.contains(hit) {indices.remove(hit)} else {indices.insert(hit)}
                            model.selectAnnotations(indices)
                            if !indices.contains(hit) {needsDisplay=true;return}
                        } else if !model.selectedAnnotations.contains(hit) {model.selectAnnotation(hit)}
                    } else {
                        marqueeStart=p;marqueeBaseline=additive ? model.selectedAnnotations : []
                        model.selectAnnotations(marqueeBaseline);needsDisplay=true;return
                    }
                }
                selectionStart=p;selectionRevision=model.revision
                selectionOriginal=Dictionary(uniqueKeysWithValues:model.selectedAnnotations.map{($0,model.document.annotations[$0])})
                if let first=selectionOriginal.values.first {selectionBounds=selectionOriginal.values.dropFirst().reduce(first.bounds){$0.union($1.bounds)}}
                needsDisplay=true;return
            }
            model.selectedAnnotation=nil
            if model.tool == .move {
                if event.clickCount == 2 { model.zoom = 1; pan = .zero; needsDisplay = true }
                lastDrag = convert(event.locationInWindow, from: nil); return
            }
            guard imageRect.contains(convert(event.locationInWindow, from: nil)) else { return }
            let p = point(event)
            var options=model.annotationOptions;options.arrowComment=""
            if model.tool == .number {
                guard (1...3999).contains(model.nextSequenceNumber) else {model.error=tr("Use a sequence number from 1 to 3999.");return}
                options.numberValue=model.nextSequenceNumber
            }
            let text=model.tool == .number ? options.numberFormat.label(model.nextSequenceNumber) : model.text
            draft = CaptureAnnotation(tool: model.tool, points: [p,p], color: NSColor(model.color), width: model.lineWidth, text: text,options:options)
            needsDisplay = true
        }
        override func mouseDragged(with event: NSEvent) {
            if updateConnectedLinePreview(event) {return}
            if model.selectingOCRText,let start=ocrDragStart {
                let p=point(event),rect=CGRect(x:min(start.x,p.x),y:min(start.y,p.y),width:max(1,abs(p.x-start.x)),height:max(1,abs(p.y-start.y)))
                model.selectedOCRSegments=ocrBaseline.union(model.ocrSegments.indices.filter{rect.intersects(model.ocrRect($0))})
                needsDisplay=true;return
            }
            guard !model.locked else{return}
            if model.tool == .crop,cropGestureRevision == model.revision,let start=cropDragStart,let original=cropDragOriginal {
                let p=point(event)
                if cropResizing {model.setCropSelection(CGRect(x:original.minX,y:original.minY,width:max(1,original.width+p.x-start.x),height:max(1,original.height+p.y-start.y)))}
                else {model.moveCrop(from:original,dx:p.x-start.x,dy:p.y-start.y)}
                needsDisplay=true;return
            }
            if model.tool == .select,let start=marqueeStart {
                let p=point(event),rect=CGRect(x:min(start.x,p.x),y:min(start.y,p.y),width:abs(p.x-start.x),height:abs(p.y-start.y))
                marqueeRect=rect
                model.selectAnnotations(marqueeBaseline.union(model.document.annotations.indices.filter{rect.intersects(model.document.annotations[$0].bounds)}))
                needsDisplay=true;return
            }
            if model.tool == .select,let start=selectionStart,let bounds=selectionBounds,selectionRevision == model.revision,Set(selectionOriginal.keys) == model.selectedAnnotations {
                let p=point(event)
                selectionMoved=selectionMoved || hypot(p.x-start.x,p.y-start.y) > 0.5/scale
                let target=CGRect(x:bounds.minX,y:bounds.minY,width:max(1,bounds.width+p.x-start.x),height:max(1,bounds.height+p.y-start.y))
                if let endpointIndex {
                    selectionPreview=selectionOriginal.mapValues {original in
                        var result=original
                        let fixed=original.points[endpointIndex == 0 ? 1 : endpointIndex-1]
                        result.points[endpointIndex]=event.modifierFlags.contains(.shift) ? CaptureAnnotation.snappedEndpoint(from:fixed,to:p,inside:model.document.size) : p
                        return result
                    }
                } else {selectionPreview=selectionOriginal.mapValues {resizing ? $0.resized(from:bounds,to:target) : $0.moved(dx:p.x-start.x,dy:p.y-start.y)}}
                needsDisplay=true;return
            }
            if model.tool == .move, let lastDrag {
                let next = convert(event.locationInWindow, from: nil)
                pan.x += next.x-lastDrag.x; pan.y += next.y-lastDrag.y; self.lastDrag = next
                needsDisplay = true; return
            }
            guard draft != nil else { return }
            if model.tool == .pencil || model.tool == .eraser { draft?.points.append(point(event)) }
            else {
                var p=point(event)
                if event.modifierFlags.contains(.shift),[CaptureTool.line,.arrow,.number].contains(model.tool),let start=draft?.points.first {
                    p=CaptureAnnotation.snappedEndpoint(from:start,to:p,inside:model.document.size)
                }
                draft?.points[1]=p
            }
            needsDisplay = true
        }
        override func mouseUp(with event: NSEvent) {
            reconcileConnectedLine()
            if model.tool == .line,model.connectedLine {return}
            lastDrag = nil
            if cropDragStart != nil {cropDragStart=nil;cropDragOriginal=nil;needsDisplay=true;return}
            if ocrDragStart != nil {ocrDragStart=nil;ocrBaseline=[];needsDisplay=true;return}
            if selectionStart != nil || marqueeStart != nil {
                if !model.locked,model.tool == .select,selectionMoved,selectionRevision == model.revision,Set(selectionOriginal.keys) == model.selectedAnnotations {
                    model.document.replaceAnnotations(selectionPreview)
                }
                cancelSelectionGesture();needsDisplay=true;return
            }
            guard !model.locked else {draft=nil;needsDisplay=true;return}
            guard let item = draft else { return }; draft = nil
            if item.tool == .select { return }
            if item.tool == .crop, let a = item.points.first, let b = item.points.last {
                if model.tool == .crop,cropGestureRevision == model.revision {model.setCropSelection(CGRect(x:min(a.x,b.x),y:min(a.y,b.y),width:abs(a.x-b.x),height:abs(a.y-b.y)))}
            } else if ![CaptureTool.text,.watermark].contains(item.tool) || !item.text.isEmpty {
                model.document.append(item)
                if item.tool == .number {model.nextSequenceNumber=(item.options.numberValue ?? model.nextSequenceNumber)+1}
            }
            needsDisplay = true
        }
        override func keyDown(with event:NSEvent) {
            if handleConnectedLineKey(event) {return}
            if model.tool == .crop {
                if event.keyCode == 53 {model.cropSelection=nil;draft=nil;cropDragStart=nil;cropDragOriginal=nil;needsDisplay=true;return}
                if !model.locked,let rect=model.cropSelection {
                    if event.keyCode == 36 || event.keyCode == 76 {model.commitCrop();needsDisplay=true;return}
                    if [123,124,125,126].contains(event.keyCode),event.modifierFlags.intersection([.command,.control,.option]).isEmpty {
                        let step:CGFloat=event.modifierFlags.contains(.shift) ? 10 : 1
                        model.moveCrop(from:rect,dx:event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0,dy:event.keyCode == 125 ? -step : event.keyCode == 126 ? step : 0)
                        needsDisplay=true;return
                    }
                }
            }
            if model.selectingOCRText {
                if event.keyCode == 53 {model.selectingOCRText=false;ocrDragStart=nil;ocrBaseline=[];needsDisplay=true;return}
                if event.modifierFlags.contains(.command),event.keyCode == 0 {model.selectedOCRSegments=Set(model.ocrSegments.indices);needsDisplay=true;return}
                if event.modifierFlags.contains(.command),event.keyCode == 8 {model.copyOCRText();return}
                if event.keyCode == 51 || event.keyCode == 117 {return}
            }
            if event.keyCode == 53 {cancelSelectionGesture();draft=nil;model.selectAnnotations([]);needsDisplay=true}
            else if event.keyCode == 0,event.modifierFlags.contains(.command) {model.selectAllAnnotations();needsDisplay=true}
            else if event.keyCode == 51 || event.keyCode == 117 {cancelSelectionGesture();model.deleteSelected();needsDisplay=true}
            else { super.keyDown(with:event) }
        }
        func cancelSelectionGesture() {
            selectionStart=nil;selectionOriginal=[:];selectionPreview=[:];selectionBounds=nil;selectionRevision=nil
            selectionMoved=false;resizing=false;endpointIndex=nil;marqueeStart=nil;marqueeRect=nil;marqueeBaseline=[]
        }
        override func scrollWheel(with event: NSEvent) {
            guard !model.locked else { return }
            model.zoom = min(4, max(0.25, model.zoom*exp(event.scrollingDeltaY*0.015)))
        }
    }
}
