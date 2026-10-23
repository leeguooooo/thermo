import AppKit
import ScreenCaptureKit
import CaptureCore
import SwiftUI
import ThermoL10n

/// Selection is restricted to one display. Rectangles are display-local, top-left points.
@MainActor final class CaptureRegionSelector {
    struct Region { let displayID: CGDirectDisplayID; let rect: CGRect; let scale: CGFloat; var selectedDisplaySize:CGSize? = nil }
    private var panels: [NSPanel] = []
    private var displayObserver:NSObjectProtocol?
    private var completion: ((Region?) -> Void)?
    private final class Panel: NSPanel { override var canBecomeKey: Bool { true } }
    func select(completion: @escaping (Region?) -> Void) {
        guard panels.isEmpty else { return }
        self.completion = completion
        for screen in NSScreen.screens {
            let panel = Panel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.backgroundColor = .clear; panel.isOpaque = false; panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.isReleasedWhenClosed = false
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            panel.title=tr("Select capture display")+" · "+screen.localizedName
            view.configure(displayName:screen.localizedName)
            view.done = { [weak self] rect in
                guard let rect, let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { self?.finish(nil); return }
                self?.finish(Region(displayID: displayID, rect: CGRect(x: rect.minX, y: screen.frame.height-rect.maxY, width: rect.width, height: rect.height), scale: screen.backingScaleFactor,selectedDisplaySize:screen.frame.size))
            }
            view.nextDisplay={ [weak self,weak panel] in
                guard let self,let panel,let index=self.panels.firstIndex(of:panel),!self.panels.isEmpty else{return}
                let next=self.panels[(index+1)%self.panels.count];next.makeKeyAndOrderFront(nil);next.makeFirstResponder(next.contentView)
            }
            panel.contentView = view; panels.append(panel)
            panel.orderFrontRegardless()
        }
        displayObserver=NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in MainActor.assumeIsolated {self?.finish(nil)} }
        guard !panels.isEmpty else {finish(nil);return}
        let initial=panels.first(where:{$0.frame.contains(NSEvent.mouseLocation)}) ?? panels[0]
        initial.makeKeyAndOrderFront(nil);initial.makeFirstResponder(initial.contentView)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func finish(_ region: Region?) {
        if let displayObserver {NotificationCenter.default.removeObserver(displayObserver)};displayObserver=nil
        for panel in panels { panel.orderOut(nil); panel.close() }; panels.removeAll()
        let callback = completion; completion = nil; callback?(region)
    }
    func cancel() { finish(nil) }
    private final class SelectionView: NSView {
        var done: ((CGRect?) -> Void)?
        var nextDisplay:(()->Void)?
        var start: CGPoint?, current: CGPoint?
        func configure(displayName:String) {
            setAccessibilityLabel(tr("Select capture display")+" · "+displayName)
            let full=NSButton(title:tr("Select entire display")+" · "+displayName,target:self,action:#selector(selectDisplay));full.keyEquivalent="\r"
            let next=NSButton(title:tr("Next display"),target:self,action:#selector(nextScreen))
            let cancel=NSButton(title:tr("Cancel"),target:self,action:#selector(cancelSelection));cancel.keyEquivalent="\u{1b}"
            var x:CGFloat=30
            for button in [full,next,cancel] {button.bezelStyle = .rounded;button.sizeToFit();button.frame.origin=CGPoint(x:x,y:bounds.height-100);addSubview(button);x=button.frame.maxX+12}
        }
        @objc private func selectDisplay() {done?(bounds)}
        @objc private func nextScreen() {nextDisplay?()}
        @objc private func cancelSelection() {done?(nil)}
        override var acceptsFirstResponder: Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 {done?(nil)}
            else if event.keyCode == 36 || event.keyCode == 76 {done?(bounds)}
            else if event.keyCode == 48 {nextDisplay?()}
            else {super.keyDown(with:event)}
        }
        override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil); current = start; needsDisplay = true }
        override func mouseDragged(with event: NSEvent) { current = convert(event.locationInWindow, from: nil); needsDisplay = true }
        override func mouseUp(with event: NSEvent) {
            current = convert(event.locationInWindow, from: nil)
            guard let rect, rect.width >= 32, rect.height >= 32 else { return }
            done?(rect)
        }
        var rect: CGRect? {
            guard let a = start, let b = current else { return nil }
            return CGRect(x: min(a.x,b.x),y: min(a.y,b.y),width: abs(a.x-b.x),height: abs(a.y-b.y)).intersection(bounds)
        }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.black.withAlphaComponent(0.25).setFill(); bounds.fill()
            if let rect { NSColor.white.setStroke(); let path = NSBezierPath(rect: rect); path.lineWidth = 2; path.stroke() }
            (tr("Drag a region. Esc cancels.") as NSString).draw(at: CGPoint(x: 30,y: bounds.height-60), withAttributes: [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.white])
        }
    }
}

@available(macOS 14, *)
@MainActor final class ScrollCaptureModel: ObservableObject {
    @Published var image: CGImage?
    @Published var running = false
    @Published var issue: String?
    @Published var frames = 0
    @Published var horizontal = false
    @Published var detectFixedEdges=true
    @Published var leadingInset=0
    @Published var trailingInset=0
    @Published private(set) var fixedLeading=0
    @Published private(set) var fixedTrailing=0
    private var captureTask: Task<Void, Never>?
    private var stitcher:CaptureScrollStitcher?
    private let region: CaptureRegionSelector.Region
    init(region: CaptureRegionSelector.Region) { self.region = region }
    func start() {
        guard captureTask == nil else { return }
        running = true; issue = nil
        let direction: CaptureStitcher.Direction = horizontal ? .horizontal : .vertical
        let initial=stitcher ?? CaptureScrollStitcher(direction:direction,detectFixedEdges:detectFixedEdges,leadingInset:leadingInset,trailingInset:trailingInset)
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == self.region.displayID }) else { throw CaptureFailure.captureFailed }
                try self.region.validateCurrentDisplay()
                try self.region.validate(displaySize:display.frame.size,scale:self.region.scale)
                let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
                let config = SCStreamConfiguration(); config.sourceRect = self.region.rect
                config.width = Int(self.region.rect.width*self.region.scale); config.height = Int(self.region.rect.height*self.region.scale)
                config.showsCursor = false
                var session=initial
                while !Task.isCancelled {
                    try self.region.validateCurrentDisplay()
                    let frame = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    guard !Task.isCancelled else { break }
                    do {
                        let snapshot=session
                        let (next,result)=try await Task.detached(priority:.userInitiated) {var next=snapshot;let result=try next.append(frame);return (next,result)}.value
                        guard !Task.isCancelled else {break}
                        session=next;self.stitcher=next;self.image=result.image
                        self.fixedLeading=result.fixedLeading;self.fixedTrailing=result.fixedTrailing
                        if !result.duplicate {self.frames+=1}
                        self.issue=nil
                    } catch {self.issue=tr(error.localizedDescription)}
                    try await Task.sleep(nanoseconds: 700_000_000)
                }
            } catch is CancellationError { }
            catch { self.issue = tr(error.localizedDescription) }
            self.running = false; self.captureTask = nil
        }
    }
    func stop() { captureTask?.cancel(); running = false }
}

@available(macOS 14, *)
@MainActor final class ScrollCaptureWindow: NSWindowController, NSWindowDelegate {
    private let model: ScrollCaptureModel
    init(region: CaptureRegionSelector.Region) {
        model = ScrollCaptureModel(region: region)
        let panel = NSPanel(contentRect: NSRect(x: 0,y: 0,width: 340,height: 480), styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
        panel.title = tr("Scrolling capture"); panel.level = .floating; panel.isReleasedWhenClosed = false; panel.center()
        super.init(window: panel); panel.delegate = self
        panel.contentView = NSHostingView(rootView: ScrollCaptureView(model: model))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    func windowWillClose(_ notification: Notification) { model.stop() }
}

@available(macOS 14, *)
private struct ScrollCaptureView: View {
    @ObservedObject var model: ScrollCaptureModel
    var body: some View {
        VStack(spacing: 12) {
            Text(tr("Scroll the selected content slowly. Thermo windows are excluded.")).font(.callout)
            Toggle(tr("Horizontal scrolling"), isOn: $model.horizontal).disabled(model.running || model.image != nil)
            Toggle(tr("Detect fixed edges"),isOn:$model.detectFixedEdges).disabled(model.running || model.image != nil)
                .help(tr("Use manual edge pixels for changing headers or footers."))
            if !model.detectFixedEdges {
                HStack {
                    Text(tr("Leading edge")).font(.caption)
                    TextField(tr("Leading edge"),value:$model.leadingInset,format:.number).frame(width:65)
                    Text(tr("Trailing edge")).font(.caption)
                    TextField(tr("Trailing edge"),value:$model.trailingInset,format:.number).frame(width:65)
                }.disabled(model.running || model.image != nil)
                Text(tr("Top / bottom for vertical scrolling; left / right for horizontal scrolling.")).font(.caption)
            }
            if let image = model.image {
                Image(nsImage: NSImage(cgImage: image,size: .zero)).resizable().scaledToFit().frame(maxHeight: .infinity)
                Text("\(image.width) × \(image.height) · \(model.frames)").font(.caption)
                Text(String(format:tr("Fixed edges: %1$@ / %2$@ px"),String(model.fixedLeading),String(model.fixedTrailing))).font(.caption)
            } else { Spacer() }
            if let issue = model.issue { Text(issue).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button(tr(model.running ? "Stop" : "Start")) { model.running ? model.stop() : model.start() }
                Button(tr("Edit / pin result")) { if let image = model.image { CaptureWorkspace.shared.open(image) } }.disabled(model.running || model.image == nil)
            }
        }.padding(16).frame(minWidth: 260,minHeight: 320)
    }
}
