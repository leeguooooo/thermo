import AppKit
import ScreenCaptureKit
import CaptureCore
import SwiftUI
import ThermoL10n

/// Selection is restricted to one display. Rectangles are display-local, top-left points.
@MainActor final class CaptureRegionSelector {
    struct Region { let displayID: CGDirectDisplayID; let rect: CGRect; let scale: CGFloat }
    private var panels: [NSPanel] = []
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
            view.done = { [weak self] rect in
                guard let rect, let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { self?.finish(nil); return }
                self?.finish(Region(displayID: displayID, rect: CGRect(x: rect.minX, y: screen.frame.height-rect.maxY, width: rect.width, height: rect.height), scale: screen.backingScaleFactor))
            }
            panel.contentView = view; panels.append(panel)
            panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(view)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    private func finish(_ region: Region?) {
        for panel in panels { panel.orderOut(nil); panel.close() }; panels.removeAll()
        let callback = completion; completion = nil; callback?(region)
    }
    private final class SelectionView: NSView {
        var done: ((CGRect?) -> Void)?
        var start: CGPoint?, current: CGPoint?
        override var acceptsFirstResponder: Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
        override func keyDown(with event: NSEvent) { if event.keyCode == 53 { done?(nil) } }
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
    private var captureTask: Task<Void, Never>?
    private let region: CaptureRegionSelector.Region
    init(region: CaptureRegionSelector.Region) { self.region = region }
    func start() {
        guard captureTask == nil else { return }
        running = true; issue = nil
        let direction: CaptureStitcher.Direction = horizontal ? .horizontal : .vertical
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == self.region.displayID }) else { throw CaptureFailure.captureFailed }
                let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
                let config = SCStreamConfiguration(); config.sourceRect = self.region.rect
                config.width = Int(self.region.rect.width*self.region.scale); config.height = Int(self.region.rect.height*self.region.scale)
                config.showsCursor = false
                while !Task.isCancelled {
                    let frame = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    guard !Task.isCancelled else { break }
                    if let previous = self.image {
                        do {
                            let result = try await Task.detached(priority: .userInitiated) { try CaptureStitcher.append(frame, to: previous, direction: direction) }.value
                            guard !Task.isCancelled else { break }
                            if !result.duplicate { self.image = result.image; self.frames += 1 }
                            self.issue = nil
                        } catch { self.issue = tr(error.localizedDescription) }
                    } else { self.image = frame; self.frames = 1 }
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
        let panel = NSPanel(contentRect: NSRect(x: 0,y: 0,width: 300,height: 390), styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
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
            if let image = model.image {
                Image(nsImage: NSImage(cgImage: image,size: .zero)).resizable().scaledToFit().frame(maxHeight: .infinity)
                Text("\(image.width) × \(image.height) · \(model.frames)").font(.caption)
            } else { Spacer() }
            if let issue = model.issue { Text(issue).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button(tr(model.running ? "Stop" : "Start")) { model.running ? model.stop() : model.start() }
                Button(tr("Edit / pin result")) { if let image = model.image { CaptureWorkspace.shared.open(image) } }.disabled(model.running || model.image == nil)
            }
        }.padding(16).frame(minWidth: 260,minHeight: 320)
    }
}
