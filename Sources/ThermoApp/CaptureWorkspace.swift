import AppKit
import CaptureCore
import Carbon
import SwiftUI
import ThermoL10n
import UniformTypeIdentifiers

@MainActor final class CaptureWorkspace: ObservableObject {
    static let shared = CaptureWorkspace()
    @Published var issue: String?
    @Published var capturing = false
    @Published var pinCount = 0
    let pinSession=CapturePinSession()
    init() { pinSession.onCountChange={ [weak self] in self?.pinCount=$0 } }
    private var process: Process?
    private var captureDirectory: URL?
    private var regionSelector: CaptureRegionSelector?
    private var scrollWindow: NSWindowController?
    private var recordingWindow: CaptureRecordingWindow?
    private let hotkeys = CarbonCleanScreenHotkeys()
    private var leases: [CleanScreenHotkeyLease] = []
    func activate() {
        guard leases.isEmpty else { return }
        pinSession.restoreWindows()
        // Deliberately different from macOS screenshot shortcuts and PixPin's shortcuts.
        for (code, action) in [(UInt32(20), { self.capture() }), (UInt32(21), { self.pinClipboard() })] {
            do {
                let binding = CleanScreenKeyBinding(keyCode: code, modifiers: UInt32(cmdKey | optionKey), keyLabel: code == 20 ? "3" : "4")
                leases.append(try hotkeys.register(binding) { down in if down { action() } })
            } catch { issue = tr("Capture shortcut unavailable. Use the Thermo menu.") }
        }
    }
    func shutdown() {
        process?.terminate()
        if let captureDirectory { try? FileManager.default.removeItem(at:captureDirectory) }; captureDirectory = nil
        regionSelector?.cancel(); regionSelector = nil
        scrollWindow?.close()
        for lease in leases { try? lease.release() }; leases.removeAll()
    }
    func capture() {
        guard !capturing else { return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else { report(CaptureFailure.captureFailed); return }
        issue = nil; capturing = true
        // The native selector supports region, Space for window, and Escape to cancel.
        // A unique private directory prevents cancelled captures from reusing old pixels.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-capture-" + UUID().uuidString, isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { capturing = false; report(error); return }
        let output = directory.appendingPathComponent("capture.png")
        captureDirectory = directory
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-i", "-x", "-t", "png", output.path]
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        task.terminationHandler = { [weak self] task in
            Task { @MainActor in
                defer { try? FileManager.default.removeItem(at: directory) }
                guard let self else { return }
                self.process = nil; self.capturing = false
                self.captureDirectory = nil
                // Escape produces no file; leave clipboard and existing pins alone.
                guard FileManager.default.fileExists(atPath: output.path) else { return }
                guard task.terminationStatus == 0 else { self.report(CaptureFailure.captureFailed); return }
                do { self.open(try CaptureDocument.load(output)) } catch { self.report(error) }
            }
        }
        do { process = task; try task.run() }
        catch { process = nil; capturing = false; captureDirectory = nil; try? FileManager.default.removeItem(at: directory); report(error) }
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
    func pinClipboard() {
        let board = NSPasteboard.general
        if let image = NSImage(pasteboard: board), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) { open(cg); return }
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            for url in urls {
                if let image = try? CaptureDocument.load(url) { open(image) }
                else { openText(url.path) }
            }
            return
        }
        if let text = board.string(forType: .string), !text.isEmpty { openText(text); return }
        report(CaptureFailure.unsupportedClipboard)
    }
    private func openText(_ text: String) {
        // Plain text pins never execute HTML, URLs or LaTeX from the clipboard.
        let content = String(text.prefix(20000))
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 18, weight: .regular), .foregroundColor: NSColor.black]
        let size = (content as NSString).boundingRect(with: CGSize(width: 640, height: 4000), options: [.usesLineFragmentOrigin], attributes: attributes).size
        let image = NSImage(size: CGSize(width: max(160, size.width+32), height: max(64, size.height+32)))
        image.lockFocus(); NSColor.white.setFill(); CGRect(origin: .zero, size: image.size).fill()
        (content as NSString).draw(in: CGRect(x: 16, y: 16, width: image.size.width-32, height: image.size.height-32), withAttributes: attributes)
        image.unlockFocus()
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) { open(cg) }
    }
    func open(_ image: CGImage) {
        do { try pinSession.open(image) } catch { report(error) }
    }
    func showPinLibrary() { pinSession.showLibrary() }
    func restoreLastPin() { do { try pinSession.restore() } catch { report(error) } }
    func showAll() { do { try pinSession.setAllHidden(false) } catch { report(error) } }
    func hideAll() { do { try pinSession.setAllHidden(true) } catch { report(error) } }
    func closeAll() { pinSession.closeAll() }
    func report(_ error: Error) { issue = tr(error.localizedDescription); showIssue() }
    private func showIssue() {
        let alert = NSAlert(); alert.messageText = tr("Screenshots and pins"); alert.informativeText = issue ?? ""; alert.runModal()
    }
}

@MainActor final class CaptureEditorModel: ObservableObject {
    @Published var document: CaptureDocument { didSet {
        revision += 1; recognition = "";onMutation?(true)
        if let selectedAnnotation,!document.annotations.indices.contains(selectedAnnotation) { self.selectedAnnotation=nil }
    } }
    private var revision = 0
    @Published var tool: CaptureTool = .move
    @Published var selectedAnnotation:Int?
    @Published var annotationOptions=CaptureAnnotationOptions()
    @Published var color = Color.red
    @Published var lineWidth: Double = 4
    @Published var text = ""
    @Published var recognition = ""
    @Published var recognizing = false
    var onMutation:((Bool)->Void)?
    var showPinLibrary:(() -> Void)?
    @Published var pinTitle="" { didSet { changeWindow?();onMutation?(false) } }
    @Published var locked=false { didSet { changeWindow?();onMutation?(false) } }
    @Published var shadow=true { didSet { changeWindow?();onMutation?(false) } }
    @Published var pan=CGPoint.zero { didSet { onMutation?(false) } }
    @Published var opacity: Double = 1 { didSet { onMutation?(false) } }
    @Published var pinned = true { didSet { onMutation?(false) } }
    @Published var error: String?
    @Published var zoom: Double = 1 { didSet { onMutation?(false) } }
    var changeWindow: (() -> Void)?
    init(image: CGImage) { document = CaptureDocument(image: image) }
    func selectAnnotation(_ index:Int?) {
        selectedAnnotation=index
        if let index,document.annotations.indices.contains(index) {
            let item=document.annotations[index];color=Color(nsColor:item.color);lineWidth=item.width;text=item.text;annotationOptions=item.options
        }
    }
    func applySelectedStyle() {
        guard let index=selectedAnnotation,document.annotations.indices.contains(index) else { return }
        var item=document.annotations[index]
        let nextColor=NSColor(color)
        guard item.color != nextColor || item.width != lineWidth || item.text != text || item.options != annotationOptions else { return }
        item.color=nextColor;item.width=lineWidth;item.text=text;item.options=annotationOptions
        document.replaceAnnotation(at:index,with:item)
    }
    func undoAnnotation() { document.undo();selectAnnotation(selectedAnnotation) }
    func redoAnnotation() { document.redo();selectAnnotation(selectedAnnotation) }
    func deleteSelected() {
        if let selectedAnnotation { document.removeAnnotation(at:selectedAnnotation) };selectedAnnotation=nil
    }
    func copy() {
        do {
            let data = try document.data()
            NSPasteboard.general.clearContents(); NSPasteboard.general.setData(data, forType: .png)
        } catch { self.error = tr(error.localizedDescription) }
    }
    func save() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png, .jpeg, .tiff]
        panel.nameFieldStringValue = "Thermo-" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + ".png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let ext = url.pathExtension.lowercased()
            let type: NSBitmapImageRep.FileType = ["jpg", "jpeg"].contains(ext) ? .jpeg : (ext == "tiff" || ext == "tif" ? .tiff : .png)
            try document.data(format: type).write(to: url, options: .atomic)
        } catch { self.error = tr(error.localizedDescription) }
    }
    func recognize() {
        guard !recognizing else { return }
        do {
            let image = try document.rendered()
            let revision = self.revision
            recognizing = true; error = nil
            Task {
                do {
                    let result = try await Task.detached(priority: .userInitiated) { try CaptureRecognition.recognize(image) }.value
                    if self.revision == revision {
                        recognition = ([result.text] + result.codes).filter { !$0.isEmpty }.joined(separator: "\n")
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
            window.title=self.model.pinTitle.isEmpty ? tr("Screenshots and pins") : self.model.pinTitle
            window.hasShadow=self.model.shadow;window.isMovable = !self.model.locked
            window.styleMask=self.model.locked ? [.titled,.closable,.miniaturizable] : [.titled,.closable,.miniaturizable,.resizable]
        }
        window.contentView = NSHostingView(rootView: CaptureEditorView(model: model))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    func windowShouldClose(_ sender:NSWindow) -> Bool { shouldClose?() ?? true }
    func windowWillClose(_ notification: Notification) { onClose() }
    func windowDidMove(_ notification:Notification) { onWindowChange?() }
    func windowDidResize(_ notification:Notification) { onWindowChange?() }
}

private struct CaptureEditorView: View {
    @ObservedObject var model: CaptureEditorModel
    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CaptureTool.allCases) { tool in
                        Button { model.tool = tool } label: { Image(systemName: tool.symbol).frame(width: 22, height: 24) }
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
                        do { try model.document.transform(rotateClockwise: true) } catch { model.error = tr(error.localizedDescription) }
                    } label: { Image(systemName: "rotate.right") }.help(tr("Rotate clockwise"))
                    Button {
                        do { try model.document.transform(flipHorizontal: true) } catch { model.error = tr(error.localizedDescription) }
                    } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }.help(tr("Flip horizontally"))
                }.padding(8)
            }
            HStack {
                TextField(tr("Pin title"),text:$model.pinTitle).textFieldStyle(.roundedBorder)
                Toggle(tr("Lock pin"),isOn:$model.locked)
                Toggle(tr("Pin shadow"),isOn:$model.shadow)
                if let show=model.showPinLibrary { Button(tr("Pin groups and history"),action:show) }
            }.padding(.horizontal,10)
            CaptureAnnotationControls(model:model)
            if model.tool == .text || model.tool == .watermark {
                TextField(tr("Annotation text"), text: $model.text).textFieldStyle(.roundedBorder).padding(8)
            }
            CaptureCanvas(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
            if !model.recognition.isEmpty {
                TextEditor(text: $model.recognition).font(.system(.body, design: .monospaced)).frame(height: 120)
                Button(tr("Copy recognized text")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.recognition, forType: .string) }.padding(4)
            }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled).padding(6) }
            if model.recognizing { HStack { ProgressView().controlSize(.small); Text(tr("Recognizing text and barcodes…")) }.padding(6) }
            HStack {
                Toggle(tr("Keep on top"), isOn: $model.pinned).onChange(of: model.pinned) { _ in model.changeWindow?() }
                Slider(value: $model.opacity, in: 0.2...1).disabled(model.locked).frame(width: 80).help(tr("Pin opacity")).onChange(of: model.opacity) { _ in model.changeWindow?() }
                Slider(value: $model.zoom, in: 0.25...4).disabled(model.locked).frame(width: 70).help(tr("Zoom"))
                Text("\(model.document.image.width) × \(model.document.image.height)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(tr("Text / QR")) { model.recognize() }.disabled(model.recognizing)
                Button(tr("Copy image")) { model.copy() }.keyboardShortcut("c", modifiers: .command)
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
    func updateNSView(_ view: Canvas, context: Context) { view.model = model; view.needsDisplay = true }
    final class Canvas: NSView {
        var model: CaptureEditorModel
        var draft: CaptureAnnotation?
        var pan:CGPoint { get { model.pan } set { model.pan=newValue } }
        var lastDrag: CGPoint?
        var selectionStart:CGPoint?
        var selectionOriginal:CaptureAnnotation?
        var resizing=false
        init(model: CaptureEditorModel) { self.model = model; super.init(frame: .zero) }
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
            ctx.saveGState(); ctx.translateBy(x: imageRect.minX, y: imageRect.minY); ctx.scaleBy(x: scale, y: scale)
            let replacement=model.tool == .select ? model.selectedAnnotation : nil
            let preview=draft?.tool == .crop ? nil : draft
            do {
                let image=try model.document.rendered(adding:preview,replacing:replacement)
                ctx.draw(image,in:CGRect(origin:.zero,size:model.document.size))
            } catch {
                ctx.setFillColor(NSColor.black.cgColor);ctx.fill(CGRect(origin:.zero,size:model.document.size))
                let message=tr(error.localizedDescription)
                DispatchQueue.main.async { [weak model] in if model?.error != message { model?.error=message } }
            }
            if let selected=model.selectedAnnotation,model.document.annotations.indices.contains(selected) {
                let rect=(model.tool == .select ? draft : nil)?.bounds ?? model.document.annotations[selected].bounds
                ctx.setStrokeColor(NSColor.systemBlue.cgColor);ctx.setLineWidth(1/scale);ctx.setLineDash(phase:0,lengths:[4/scale,3/scale]);ctx.stroke(rect);ctx.setLineDash(phase:0,lengths:[])
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
            if model.locked { return }
            if model.tool == .select {
                let p=point(event)
                if let selected=model.selectedAnnotation,model.document.annotations.indices.contains(selected) {
                    let bounds=model.document.annotations[selected].bounds
                    resizing=hypot(p.x-bounds.maxX,p.y-bounds.maxY) < 10/scale
                }
                if !resizing { model.selectAnnotation(model.document.hitTest(p,tolerance:5/scale)) }
                if let selected=model.selectedAnnotation,model.document.annotations.indices.contains(selected) { selectionStart=p;selectionOriginal=model.document.annotations[selected];draft=selectionOriginal }
                needsDisplay=true;return
            }
            model.selectedAnnotation=nil
            if model.tool == .move {
                if event.clickCount == 2 { model.zoom = 1; pan = .zero; needsDisplay = true }
                lastDrag = convert(event.locationInWindow, from: nil); return
            }
            guard imageRect.contains(convert(event.locationInWindow, from: nil)) else { return }
            let p = point(event)
            let text = model.tool == .number ? String(model.document.annotations.filter { $0.tool == .number }.count+1) : model.text
            draft = CaptureAnnotation(tool: model.tool, points: [p,p], color: NSColor(model.color), width: model.lineWidth, text: text,options:model.annotationOptions)
            needsDisplay = true
        }
        override func mouseDragged(with event: NSEvent) {
            if model.tool == .select,let start=selectionStart,let original=selectionOriginal {
                let p=point(event)
                draft=resizing ? original.resized(to:CGRect(x:original.bounds.minX,y:original.bounds.minY,width:max(1,p.x-original.bounds.minX),height:max(1,p.y-original.bounds.minY))) : original.moved(dx:p.x-start.x,dy:p.y-start.y)
                needsDisplay=true;return
            }
            if model.tool == .move, let lastDrag {
                let next = convert(event.locationInWindow, from: nil)
                pan.x += next.x-lastDrag.x; pan.y += next.y-lastDrag.y; self.lastDrag = next
                needsDisplay = true; return
            }
            guard draft != nil else { return }
            if model.tool == .pencil || model.tool == .eraser { draft?.points.append(point(event)) } else { draft?.points[1] = point(event) }
            needsDisplay = true
        }
        override func mouseUp(with event: NSEvent) {
            lastDrag = nil
            guard let item = draft else { return }; draft = nil
            if item.tool == .select { return }
            if model.tool == .select,let selected=model.selectedAnnotation {
                model.document.replaceAnnotation(at:selected,with:item);selectionStart=nil;selectionOriginal=nil;resizing=false;needsDisplay=true;return
            }
            if item.tool == .crop, let a = item.points.first, let b = item.points.last {
                do { try model.document.crop(to: CGRect(x: min(a.x,b.x), y: min(a.y,b.y), width: abs(a.x-b.x), height: abs(a.y-b.y))) }
                catch { model.error = tr(error.localizedDescription) }
            } else if ![CaptureTool.text,.watermark].contains(item.tool) || !item.text.isEmpty { model.document.append(item) }
            needsDisplay = true
        }
        override func keyDown(with event:NSEvent) {
            if event.keyCode == 51 || event.keyCode == 117 { model.deleteSelected();needsDisplay=true }
            else { super.keyDown(with:event) }
        }
        override func scrollWheel(with event: NSEvent) {
            guard !model.locked else { return }
            model.zoom = min(4, max(0.25, model.zoom*exp(event.scrollingDeltaY*0.015)))
        }
    }
}
