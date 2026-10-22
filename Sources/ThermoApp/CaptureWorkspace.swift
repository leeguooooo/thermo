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
    private var windows: [UUID: CaptureEditor] = [:]
    private var process: Process?
    private var regionSelector: CaptureRegionSelector?
    private var scrollWindow: NSWindowController?
    private let hotkeys = CarbonCleanScreenHotkeys()
    private var leases: [CleanScreenHotkeyLease] = []
    func activate() {
        guard leases.isEmpty else { return }
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
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-i", "-x", "-t", "png", output.path]
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        task.terminationHandler = { [weak self] task in
            Task { @MainActor in
                defer { try? FileManager.default.removeItem(at: directory) }
                guard let self else { return }
                self.process = nil; self.capturing = false
                // Escape produces no file; leave clipboard and existing pins alone.
                guard FileManager.default.fileExists(atPath: output.path) else { return }
                guard task.terminationStatus == 0 else { self.report(CaptureFailure.captureFailed); return }
                do { self.open(try CaptureDocument.load(output)) } catch { self.report(error) }
            }
        }
        do { process = task; try task.run() }
        catch { process = nil; capturing = false; try? FileManager.default.removeItem(at: directory); report(error) }
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
        let id = UUID()
        let editor = CaptureEditor(image: image) { [weak self] in self?.windows.removeValue(forKey: id); self?.pinCount = self?.windows.count ?? 0 }
        windows[id] = editor; pinCount = windows.count; editor.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true); editor.window?.makeKeyAndOrderFront(nil)
    }
    func showAll() { for editor in windows.values { editor.showWindow(nil) } }
    func hideAll() { for editor in windows.values { editor.window?.orderOut(nil) } }
    func closeAll() { for editor in Array(windows.values) { editor.close() } }
    func report(_ error: Error) { issue = tr(error.localizedDescription); showIssue() }
    private func showIssue() {
        let alert = NSAlert(); alert.messageText = tr("Screenshots and pins"); alert.informativeText = issue ?? ""; alert.runModal()
    }
}

@MainActor final class CaptureEditorModel: ObservableObject {
    @Published var document: CaptureDocument { didSet { revision += 1; recognition = "" } }
    private var revision = 0
    @Published var tool: CaptureTool = .move
    @Published var color = Color.red
    @Published var lineWidth: Double = 4
    @Published var text = ""
    @Published var recognition = ""
    @Published var recognizing = false
    @Published var opacity: Double = 1
    @Published var pinned = true
    @Published var error: String?
    @Published var zoom: Double = 1
    var changeWindow: (() -> Void)?
    init(image: CGImage) { document = CaptureDocument(image: image) }
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
    init(image: CGImage, onClose: @escaping () -> Void) {
        model = CaptureEditorModel(image: image); self.onClose = onClose
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 650), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = tr("Screenshots and pins"); window.isReleasedWhenClosed = false
        window.level = .floating; window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.minSize = NSSize(width: 600, height: 360); window.center()
        super.init(window: window); window.delegate = self
        model.changeWindow = { [weak self] in
            guard let self, let window = self.window else { return }
            window.alphaValue = self.model.opacity; window.level = self.model.pinned ? .floating : .normal
        }
        window.contentView = NSHostingView(rootView: CaptureEditorView(model: model))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    func windowWillClose(_ notification: Notification) { onClose() }
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
                    Button { model.document.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!model.document.canUndo).help(tr("Undo"))
                    Button { model.document.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!model.document.canRedo).help(tr("Redo"))
                    Button {
                        do { try model.document.transform(rotateClockwise: true) } catch { model.error = tr(error.localizedDescription) }
                    } label: { Image(systemName: "rotate.right") }.help(tr("Rotate clockwise"))
                    Button {
                        do { try model.document.transform(flipHorizontal: true) } catch { model.error = tr(error.localizedDescription) }
                    } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }.help(tr("Flip horizontally"))
                }.padding(8)
            }
            if model.tool == .text {
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
                Slider(value: $model.opacity, in: 0.2...1).frame(width: 80).help(tr("Pin opacity")).onChange(of: model.opacity) { _ in model.changeWindow?() }
                Slider(value: $model.zoom, in: 0.25...4).frame(width: 70).help(tr("Zoom"))
                Text("\(model.document.image.width) × \(model.document.image.height)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(tr("Text / QR")) { model.recognize() }.disabled(model.recognizing)
                Button(tr("Copy image")) { model.copy() }.keyboardShortcut("c", modifiers: .command)
                Button(tr("Save image…")) { model.save() }.keyboardShortcut("s", modifiers: .command)
            }.padding(10)
        }
    }
}

private extension CaptureTool {
    var label: String {
        switch self {
        case .move: return "Move / view"; case .rectangle: return "Rectangle"; case .ellipse: return "Ellipse"
        case .line: return "Line"; case .arrow: return "Arrow"; case .pencil: return "Pencil"
        case .highlight: return "Highlighter"; case .redact: return "Opaque redaction"; case .text: return "Text"
        case .number: return "Sequence number"; case .crop: return "Crop (flattens annotations)"
        }
    }
    var symbol: String {
        switch self {
        case .move: return "hand.draw"; case .rectangle: return "rectangle"; case .ellipse: return "circle"
        case .line: return "line.diagonal"; case .arrow: return "arrow.up.right"; case .pencil: return "pencil.tip"
        case .highlight: return "highlighter"; case .redact: return "square.fill"; case .text: return "textformat"
        case .number: return "1.circle"; case .crop: return "crop"
        }
    }
}

private struct CaptureCanvas: NSViewRepresentable {
    @ObservedObject var model: CaptureEditorModel
    func makeNSView(context: Context) -> Canvas { Canvas(model: model) }
    func updateNSView(_ view: Canvas, context: Context) { view.model = model; view.needsDisplay = true }
    final class Canvas: NSView {
        var model: CaptureEditorModel
        var draft: CaptureAnnotation?
        var pan: CGPoint = .zero
        var lastDrag: CGPoint?
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
            ctx.draw(model.document.image, in: CGRect(origin: .zero, size: model.document.size))
            for item in model.document.annotations { CaptureDocument.draw(item, in: ctx) }
            if let draft {
                if draft.tool == .crop, let start = draft.points.first, let end = draft.points.last {
                    ctx.setStrokeColor(NSColor.systemBlue.cgColor); ctx.setLineWidth(2/scale)
                    ctx.stroke(CGRect(x: min(start.x,end.x), y: min(start.y,end.y), width: abs(end.x-start.x), height: abs(end.y-start.y)))
                } else { CaptureDocument.draw(draft, in: ctx) }
            }
            ctx.restoreGState()
        }
        override func mouseDown(with event: NSEvent) {
            if model.tool == .move {
                if event.clickCount == 2 { model.zoom = 1; pan = .zero; needsDisplay = true }
                lastDrag = convert(event.locationInWindow, from: nil); return
            }
            guard imageRect.contains(convert(event.locationInWindow, from: nil)) else { return }
            let p = point(event)
            let text = model.tool == .number ? String(model.document.annotations.filter { $0.tool == .number }.count+1) : model.text
            draft = CaptureAnnotation(tool: model.tool, points: [p,p], color: NSColor(model.color), width: model.lineWidth, text: text)
            needsDisplay = true
        }
        override func mouseDragged(with event: NSEvent) {
            if model.tool == .move, let lastDrag {
                let next = convert(event.locationInWindow, from: nil)
                pan.x += next.x-lastDrag.x; pan.y += next.y-lastDrag.y; self.lastDrag = next
                needsDisplay = true; return
            }
            guard draft != nil else { return }
            if model.tool == .pencil { draft?.points.append(point(event)) } else { draft?.points[1] = point(event) }
            needsDisplay = true
        }
        override func mouseUp(with event: NSEvent) {
            lastDrag = nil
            guard let item = draft else { return }; draft = nil
            if item.tool == .crop, let a = item.points.first, let b = item.points.last {
                do { try model.document.crop(to: CGRect(x: min(a.x,b.x), y: min(a.y,b.y), width: abs(a.x-b.x), height: abs(a.y-b.y))) }
                catch { model.error = tr(error.localizedDescription) }
            } else if item.tool != .text || !item.text.isEmpty { model.document.append(item) }
            needsDisplay = true
        }
        override func scrollWheel(with event: NSEvent) {
            model.zoom = min(4, max(0.25, model.zoom*exp(event.scrollingDeltaY*0.015)))
        }
    }
}
