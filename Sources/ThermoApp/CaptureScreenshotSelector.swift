import AppKit
import CaptureCore
import ScreenCaptureKit
import ThermoL10n

/// Thermo's own region picker for screenshots. Every display is frozen before the overlay appears,
/// so menus and hover states stay as they were when the shortcut was pressed. Hovering highlights
/// the window under the pointer (click takes it); dragging draws a region; the selection can then
/// be moved, resized from eight handles or nudged with the arrow keys before confirming.
@available(macOS 14, *)
@MainActor final class CaptureScreenshotSelector {
    enum Outcome { case cancelled, captured(CGImage, after: [CaptureAfterStep]?), region(CaptureRegionSelector.Region) }
    /// `.screenshot` crops the frozen frame; `.region` only reports where (long screenshots, recording).
    enum Purpose { case screenshot, region(confirmTitle: String) }
    let purpose: Purpose
    init(purpose: Purpose = .screenshot) { self.purpose = purpose }
    struct Frozen { let screen: NSScreen; let displayID: CGDirectDisplayID; let image: CGImage; let windows: [CGRect] }

    private var panels: [NSPanel] = []
    private var views: [SelectorView] = []
    private var completion: ((Result<Outcome, Error>) -> Void)?
    private var loading: Task<Void, Never>?
    private var displayObserver: NSObjectProtocol?

    func start(completion: @escaping (Result<Outcome, Error>) -> Void) {
        guard self.completion == nil else { return }
        self.completion = completion
        loading = Task { [weak self] in
            do {
                let frozen = try await Self.freezeDisplays()
                guard let self, !Task.isCancelled, self.completion != nil else { return }
                self.present(frozen)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.finish(.failure(error))
            }
        }
    }

    func cancel() { finish(.success(.cancelled)) }

    private func finish(_ result: Result<Outcome, Error>) {
        loading?.cancel(); loading = nil
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
        displayObserver = nil
        for panel in panels { panel.orderOut(nil); panel.close() }
        panels.removeAll(); views.removeAll()
        NSCursor.unhide()
        let callback = completion; completion = nil; callback?(result)
    }

    /// Captures each display at native resolution and records the on-screen windows, front to back,
    /// in each display's local top-left coordinates.
    static func freezeDisplays() async throws -> [Frozen] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        // Thermo's own windows (pins, the console) are fair targets too; the selector's panels do
        // not exist yet when this list is taken.
        let windowBounds: [CGRect] = info.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? Int) == 0 || isPinLevel(entry),
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let dict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict), rect.width >= 40, rect.height >= 40 else { return nil }
            return rect
        }
        var result: [Frozen] = []
        for screen in NSScreen.screens {
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let config = SCStreamConfiguration()
            config.width = Int(CGFloat(display.width) * screen.backingScaleFactor)
            config.height = Int(CGFloat(display.height) * screen.backingScaleFactor)
            config.showsCursor = false
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let origin = CGDisplayBounds(id).origin
            result.append(Frozen(screen: screen, displayID: id, image: image, windows: windowBounds.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }))
        }
        guard !result.isEmpty else { throw CaptureFailure.captureFailed }
        return result
    }

    /// Pins float above normal windows (non-zero layer) but are still windows a user would pick.
    private static func isPinLevel(_ entry: [String: Any]) -> Bool {
        (entry[kCGWindowOwnerPID as String] as? pid_t) == ProcessInfo.processInfo.processIdentifier
            && (entry[kCGWindowLayer as String] as? Int).map { $0 > 0 && $0 < Int(CGWindowLevelForKey(.mainMenuWindow)) } == true
    }

    private func present(_ frozen: [Frozen]) {
        for item in frozen {
            let panel = SelectorPanel(contentRect: item.screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .screenSaver; panel.isOpaque = true; panel.backgroundColor = .black
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.isReleasedWhenClosed = false; panel.acceptsMouseMovedEvents = true; panel.hidesOnDeactivate = false
            panel.title = tr("Select a screenshot region")
            let view = SelectorView(frame: NSRect(origin: .zero, size: item.screen.frame.size), frozen: item, purpose: purpose)
            view.onFinish = { [weak self] outcome in self?.finish(.success(outcome)) }
            view.onBeginSelection = { [weak self, weak view] in
                for other in self?.views ?? [] where other !== view { other.clearSelection() }
            }
            panel.contentView = view
            panel.setFrame(item.screen.frame, display: false)
            panels.append(panel); views.append(view)
            panel.orderFrontRegardless()
        }
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        let initial = panels.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? panels[0]
        initial.makeKeyAndOrderFront(nil); initial.makeFirstResponder(initial.contentView)
        for view in views { view.refreshHover() }
    }
}

private final class SelectorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@available(macOS 14, *)
private final class SelectorView: NSView {
    private typealias G = CaptureSelectionGeometry
    private enum Drag { case none, drawing(start: CGPoint), moving(grab: CGPoint, original: CGRect), resizing(CaptureSelectionHandle) }

    let frozen: CaptureScreenshotSelector.Frozen
    let purpose: CaptureScreenshotSelector.Purpose
    var onFinish: ((CaptureScreenshotSelector.Outcome) -> Void)?
    var onBeginSelection: (() -> Void)?

    private let scale: CGFloat
    private var hovered: CGRect?
    private var selection: CGRect?
    private var drag: Drag = .none
    private var mouseDownPoint: CGPoint?
    private var drawing = false
    private var pointer: CGPoint?
    private let toolbar = NSStackView()
    /// Marks drawn on the selection before confirming, in view coordinates (display points).
    private struct Mark { let tool: CaptureTool; var points: [CGPoint] }
    private var tool: CaptureTool?
    private var marks: [Mark] = []
    private var draft: Mark?
    private var toolButtons: [CaptureTool: NSButton] = [:]
    static let markTools: [(CaptureTool, String, String, String)] = [
        (.rectangle, "rectangle", "Rectangle", "r"), (.arrow, "arrow.up.right", "Arrow", "a"),
        (.pencil, "pencil.tip", "Pencil", "p"), (.mosaic, "checkerboard.rectangle", "Mosaic", "m")]

    init(frame: NSRect, frozen: CaptureScreenshotSelector.Frozen, purpose: CaptureScreenshotSelector.Purpose) {
        self.frozen = frozen; self.purpose = purpose
        scale = frame.width > 0 ? CGFloat(frozen.image.width) / frame.width : frozen.screen.backingScaleFactor
        super.init(frame: frame)
        setAccessibilityLabel(tr("Select a screenshot region") + " · " + frozen.screen.localizedName)
        toolbar.orientation = .horizontal; toolbar.spacing = 6; toolbar.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        toolbar.wantsLayer = true; toolbar.layer?.cornerRadius = 7; toolbar.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
        if case .screenshot = purpose {
            for (tool, symbol, title, key) in Self.markTools {
                let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tr(title)) ?? NSImage(), target: self, action: #selector(pickTool(_:)))
                button.setButtonType(.pushOnPushOff); button.bezelStyle = .texturedRounded; button.toolTip = tr(title) + " (" + key.uppercased() + ")"
                button.identifier = NSUserInterfaceItemIdentifier(tool.rawValue)
                toolButtons[tool] = button; toolbar.addArrangedSubview(button)
            }
            let undo = NSButton(image: NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: tr("Undo")) ?? NSImage(), target: self, action: #selector(undoMark))
            undo.bezelStyle = .texturedRounded; undo.toolTip = tr("Undo") + " (⌘Z)"
            toolbar.addArrangedSubview(undo)
        }
        var buttons = [(tr("Cancel"), #selector(cancelSelection))]
        switch purpose {
        case .screenshot: buttons += [(tr("Copy"), #selector(copySelection)), (tr("Done"), #selector(confirmSelection))]
        case .region(let title): buttons += [(title, #selector(confirmSelection))]
        }
        for (title, action) in buttons {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded; button.controlSize = .regular
            if action == #selector(confirmSelection) { button.keyEquivalent = "\r" }
            toolbar.addArrangedSubview(button)
        }
        toolbar.isHidden = true
        addSubview(toolbar)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: State

    func clearSelection() {
        selection = nil; drag = .none; toolbar.isHidden = true
        marks.removeAll(); draft = nil; setTool(nil); needsDisplay = true
    }

    private func setTool(_ next: CaptureTool?) {
        tool = next
        for (key, button) in toolButtons { button.state = key == next ? .on : .off }
        needsDisplay = true
    }
    @objc private func pickTool(_ sender: NSButton) {
        let picked = sender.identifier.flatMap { CaptureTool(rawValue: $0.rawValue) }
        setTool(picked == tool ? nil : picked)
        window?.makeFirstResponder(self)
    }
    @objc private func undoMark() { if !marks.isEmpty { marks.removeLast(); needsDisplay = true } }

    func refreshHover() {
        guard let window else { return }
        let location = window.mouseLocationOutsideOfEventStream
        let point = convert(location, from: nil)
        if bounds.contains(point) { updateHover(point) } else { pointer = nil; hovered = nil; needsDisplay = true }
    }

    private func updateHover(_ point: CGPoint) {
        pointer = point
        if selection == nil { hovered = G.window(at: point, in: frozen.windows, bounds: bounds) ?? bounds }
        needsDisplay = true
    }

    private var target: CGRect? { selection ?? hovered }

    // MARK: Mouse

    override func mouseEntered(with event: NSEvent) {
        window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(self)
        updateHover(convert(event.locationInWindow, from: nil))
    }
    override func mouseExited(with event: NSEvent) { pointer = nil; if selection == nil { hovered = nil }; needsDisplay = true }
    override func mouseMoved(with event: NSEvent) { updateHover(convert(event.locationInWindow, from: nil)); updateCursor() }
    override func cursorUpdate(with event: NSEvent) { updateCursor() }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pointer = point; mouseDownPoint = point
        if let tool, let selection {
            // With a tool picked, drags inside the selection draw; the selection itself stays put.
            if selection.contains(point) { draft = Mark(tool: tool, points: [point]) }
            return
        }
        if event.clickCount == 2, let selection, selection.contains(point) { finish(after: nil); return }
        if let selection {
            if let handle = G.handle(at: point, of: selection) { drag = .resizing(handle); return }
            if selection.contains(point) { drag = .moving(grab: point, original: selection); return }
        }
        drag = .drawing(start: point)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pointer = point
        if var mark = draft, let selection {
            let clamped = CGPoint(x: min(max(point.x, selection.minX), selection.maxX), y: min(max(point.y, selection.minY), selection.maxY))
            if mark.tool == .pencil { mark.points.append(clamped) } else { mark.points = [mark.points[0], clamped] }
            draft = mark; needsDisplay = true; return
        }
        switch drag {
        case .drawing(let start):
            if !drawing {
                guard hypot(point.x - start.x, point.y - start.y) >= G.clickSlop else { return }
                drawing = true; onBeginSelection?()
            }
            selection = G.rect(from: start, to: point, in: bounds); hovered = nil
        case .moving(let grab, let original):
            selection = G.move(original, by: point.x - grab.x, point.y - grab.y, in: bounds)
        case .resizing(let handle):
            if let selection { self.selection = G.resize(selection, handle: handle, to: point, in: bounds) }
        case .none: break
        }
        toolbar.isHidden = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let mark = draft {
            draft = nil
            let a = mark.points.first!, b = mark.points.last!
            if mark.tool == .pencil ? mark.points.count > 1 : hypot(b.x - a.x, b.y - a.y) >= 3 { marks.append(mark) }
            needsDisplay = true; return
        }
        defer { drag = .none; drawing = false; mouseDownPoint = nil; layoutToolbar(); needsDisplay = true }
        if case .drawing = drag {
            if !drawing {
                // A click takes the highlighted window (or the whole display).
                if selection == nil || !(selection?.contains(point) ?? false) {
                    onBeginSelection?()
                    selection = G.window(at: point, in: frozen.windows, bounds: bounds) ?? bounds
                }
            }
        }
        if let selection, selection.width < G.minimumSide || selection.height < G.minimumSide { clearSelection() }
    }

    override func rightMouseDown(with event: NSEvent) {
        if tool != nil { setTool(nil); return }
        if selection != nil { clearSelection(); updateHover(convert(event.locationInWindow, from: nil)) } else { onFinish?(.cancelled) }
    }

    private func updateCursor() {
        guard let pointer, let selection, case .none = drag, tool == nil else { NSCursor.crosshair.set(); return }
        if let handle = G.handle(at: pointer, of: selection) {
            switch handle {
            case .left, .right: NSCursor.resizeLeftRight.set()
            case .top, .bottom: NSCursor.resizeUpDown.set()
            default: NSCursor.crosshair.set()
            }
        } else if selection.contains(pointer) { NSCursor.openHand.set() } else { NSCursor.crosshair.set() }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let step: CGFloat = flags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 53: onFinish?(.cancelled)                                   // Esc
        case 36, 76: finish(after: nil)                                  // Return, Enter
        case 123, 124, 125, 126:                                         // arrows
            guard var rect = selection, marks.isEmpty, tool == nil else { return }
            let dx: CGFloat = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
            let dy: CGFloat = event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0
            if flags.contains(.option) {
                // Option grows/shrinks from the bottom-right corner.
                rect.size.width = max(G.minimumSide, rect.width + dx); rect.size.height = max(G.minimumSide, rect.height + dy)
                rect = G.clamp(rect, to: bounds)
            } else { rect = G.move(rect, by: dx, dy, in: bounds) }
            selection = rect; layoutToolbar(); needsDisplay = true
        default:
            let key = event.charactersIgnoringModifiers?.lowercased()
            if flags.contains(.command), key == "z" { undoMark() }
            else if flags.isEmpty, selection != nil, case .screenshot = purpose, let pick = Self.markTools.first(where: { $0.3 == key }) { setTool(tool == pick.0 ? nil : pick.0) }
            else if flags.contains(.command), key == "c", case .screenshot = purpose { finish(after: [.copyImage]) }
            else if flags.contains(.command), key == "a" { onBeginSelection?(); selection = bounds; hovered = nil; layoutToolbar(); needsDisplay = true }
            else if flags.isEmpty, key == "c", let pointer, let hex = color(at: pointer)?.hex {
                // Copy the color under the pointer, as a colour picker would, then close.
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(hex, forType: .string)
                onFinish?(.cancelled)
            } else { super.keyDown(with: event) }
        }
    }

    @objc private func cancelSelection() { onFinish?(.cancelled) }
    @objc private func copySelection() { finish(after: [.copyImage]) }
    @objc private func confirmSelection() { finish(after: nil) }

    private func finish(after: [CaptureAfterStep]?) {
        if case .region = purpose {
            // Recording and long screenshots need at least 32 points each way (see Region.validate).
            guard let rect = target?.integral.intersection(bounds), rect.width >= 32, rect.height >= 32 else { NSSound.beep(); return }
            onFinish?(.region(CaptureRegionSelector.Region(displayID: frozen.displayID, rect: rect, scale: frozen.screen.backingScaleFactor,
                                                           selectedDisplaySize: frozen.screen.frame.size)))
            return
        }
        guard let rect = target, let pixels = G.pixelRect(rect, scale: scale, imageSize: CGSize(width: frozen.image.width, height: frozen.image.height)),
              let cropped = frozen.image.cropping(to: pixels) else { return }
        guard !marks.isEmpty else { onFinish?(.captured(cropped, after: after)); return }
        var document = CaptureDocument(image: cropped)
        for mark in marks {
            let points = mark.points.map { G.imagePoint($0, scale: scale, crop: pixels) }
            document.append(CaptureAnnotation(tool: mark.tool, points: points, color: .systemRed, width: max(2, (2 * scale).rounded())))
        }
        guard let image = try? document.rendered() else { NSSound.beep(); return }
        onFinish?(.captured(image, after: after))
    }

    // MARK: Drawing

    private func layoutToolbar() {
        guard let selection, case .none = drag else { toolbar.isHidden = true; return }
        toolbar.isHidden = false
        let size = toolbar.fittingSize
        var origin = CGPoint(x: selection.maxX - size.width, y: selection.maxY + 8)
        if origin.y + size.height > bounds.maxY - 4 { origin.y = selection.minY - size.height - 8 }
        if origin.y < bounds.minY + 4 { origin.y = selection.maxY - size.height - 8 }
        origin.x = min(max(origin.x, bounds.minX + 4), bounds.maxX - size.width - 4)
        toolbar.frame = CGRect(origin: origin, size: size)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // The view is flipped; draw the frozen frame upright.
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height); context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(frozen.image, in: bounds)
        context.restoreGState()

        let dim = NSBezierPath(rect: bounds)
        if let target { dim.append(NSBezierPath(rect: target)); dim.windingRule = .evenOdd }
        NSColor.black.withAlphaComponent(0.4).setFill(); dim.fill()

        if let target {
            let border = NSBezierPath(rect: target.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = selection == nil ? 2 : 1.5
            NSColor.controlAccentColor.setStroke(); border.stroke()
            drawSizeLabel(for: target)
            if let selection, case .none = drag {
                for handle in CaptureSelectionHandle.allCases {
                    let p = G.handlePoint(handle, of: selection)
                    let dot = NSBezierPath(ovalIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
                    NSColor.white.setFill(); dot.fill(); NSColor.controlAccentColor.setStroke(); dot.lineWidth = 1.5; dot.stroke()
                }
            }
        }
        for mark in marks + (draft.map { [$0] } ?? []) { drawMark(mark, in: context) }
        if let pointer, showsMagnifier { drawMagnifier(at: pointer, in: context) }
    }

    /// On-screen preview of a mark; the saved image is rendered by CaptureDocument from the same points.
    private func drawMark(_ mark: Mark, in context: CGContext) {
        guard let a = mark.points.first, let b = mark.points.last else { return }
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        NSColor.systemRed.setStroke()
        switch mark.tool {
        case .rectangle:
            let path = NSBezierPath(rect: rect); path.lineWidth = 2; path.stroke()
        case .arrow:
            let path = NSBezierPath(); path.lineWidth = 2; path.lineCapStyle = .round
            path.move(to: a); path.line(to: b)
            let angle = atan2(b.y - a.y, b.x - a.x), head: CGFloat = 12
            for side in [-0.45, 0.45] {
                path.move(to: b); path.line(to: CGPoint(x: b.x - head * cos(angle + side), y: b.y - head * sin(angle + side)))
            }
            path.stroke()
        case .pencil:
            let path = NSBezierPath(); path.lineWidth = 2; path.lineCapStyle = .round; path.lineJoinStyle = .round
            path.move(to: a); for point in mark.points.dropFirst() { path.line(to: point) }; path.stroke()
        case .mosaic:
            // Pixelate the frozen frame: draw a tiny copy back at full size without smoothing.
            guard rect.width >= 2, rect.height >= 2,
                  let pixels = G.pixelRect(rect, scale: scale, imageSize: CGSize(width: frozen.image.width, height: frozen.image.height)),
                  let crop = frozen.image.cropping(to: pixels) else { return }
            let cells = CGSize(width: max(1, (rect.width / 8).rounded()), height: max(1, (rect.height / 8).rounded()))
            guard let small = CGContext(data: nil, width: Int(cells.width), height: Int(cells.height), bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            small.interpolationQuality = .medium
            small.draw(crop, in: CGRect(origin: .zero, size: cells))
            guard let tiny = small.makeImage() else { return }
            context.saveGState()
            context.interpolationQuality = .none
            context.translateBy(x: 0, y: rect.maxY + rect.minY); context.scaleBy(x: 1, y: -1)
            context.draw(tiny, in: rect)
            context.restoreGState()
        default: break
        }
    }

    private var showsMagnifier: Bool {
        if tool != nil { return false }
        switch drag {
        case .moving: return false
        case .none: return selection == nil
        default: return true
        }
    }

    private func drawSizeLabel(for rect: CGRect) {
        let size = G.pixelSize(rect, scale: scale)
        let text = "\(size.width) × \(size.height)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let textSize = text.size(withAttributes: attributes)
        var box = CGRect(x: rect.minX, y: rect.minY - textSize.height - 10, width: textSize.width + 12, height: textSize.height + 6)
        if box.minY < bounds.minY + 2 { box.origin.y = rect.minY + 4; box.origin.x = rect.minX + 4 }
        box.origin.x = min(box.minX, bounds.maxX - box.width - 2)
        NSColor.black.withAlphaComponent(0.75).setFill(); NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        text.draw(at: CGPoint(x: box.minX + 6, y: box.minY + 3), withAttributes: attributes)
    }

    /// 15×15 image pixels around the pointer, enlarged without smoothing, with coordinates and colour.
    private func drawMagnifier(at point: CGPoint, in context: CGContext) {
        let cells = 15, cell: CGFloat = 8
        let side = CGFloat(cells) * cell
        let center = CGPoint(x: (point.x * scale).rounded(.down), y: (point.y * scale).rounded(.down))
        let source = CGRect(x: center.x - CGFloat(cells / 2), y: center.y - CGFloat(cells / 2), width: CGFloat(cells), height: CGFloat(cells))
        let infoHeight: CGFloat = 36
        var frame = CGRect(x: point.x + 20, y: point.y + 20, width: side, height: side + infoHeight)
        if frame.maxX > bounds.maxX - 4 { frame.origin.x = point.x - 20 - side }
        if frame.maxY > bounds.maxY - 4 { frame.origin.y = point.y - 20 - frame.height }
        let lens = CGRect(x: frame.minX, y: frame.minY, width: side, height: side)

        NSColor.black.withAlphaComponent(0.8).setFill(); NSBezierPath(roundedRect: frame.insetBy(dx: -2, dy: -2), xRadius: 6, yRadius: 6).fill()
        if let crop = frozen.image.cropping(to: source.intersection(CGRect(x: 0, y: 0, width: frozen.image.width, height: frozen.image.height))) {
            // Edge pixels: place the crop where it sits inside the 15×15 window.
            let clipped = source.intersection(CGRect(x: 0, y: 0, width: frozen.image.width, height: frozen.image.height))
            let dest = CGRect(x: lens.minX + (clipped.minX - source.minX) * cell, y: lens.minY + (clipped.minY - source.minY) * cell,
                              width: clipped.width * cell, height: clipped.height * cell)
            context.saveGState()
            context.interpolationQuality = .none
            context.translateBy(x: 0, y: dest.maxY + dest.minY); context.scaleBy(x: 1, y: -1)
            context.draw(crop, in: dest)
            context.restoreGState()
        }
        let mid = CGRect(x: lens.minX + CGFloat(cells / 2) * cell, y: lens.minY + CGFloat(cells / 2) * cell, width: cell, height: cell)
        NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
        CGRect(x: lens.minX, y: mid.minY, width: side, height: cell).fill(using: .sourceOver)
        CGRect(x: mid.minX, y: lens.minY, width: cell, height: side).fill(using: .sourceOver)
        NSColor.white.setStroke(); let box = NSBezierPath(rect: mid); box.lineWidth = 1; box.stroke()

        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.white]
        let position = "\(Int(center.x)), \(Int(center.y))" as NSString
        position.draw(at: CGPoint(x: lens.minX + 4, y: lens.maxY + 3), withAttributes: attributes)
        if let color = color(at: point) {
            let swatch = CGRect(x: lens.minX + 4, y: lens.maxY + 19, width: 12, height: 12)
            color.ns.setFill(); NSBezierPath(rect: swatch).fill()
            ((color.hex + "  " + tr("C copies")) as NSString).draw(at: CGPoint(x: swatch.maxX + 6, y: lens.maxY + 18), withAttributes: attributes)
        }
    }

    private func color(at point: CGPoint) -> (ns: NSColor, hex: String)? {
        let x = Int(point.x * scale), y = Int(point.y * scale)
        guard x >= 0, y >= 0, x < frozen.image.width, y < frozen.image.height,
              let pixel = frozen.image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let ns = NSColor(srgbRed: CGFloat(bytes[0]) / 255, green: CGFloat(bytes[1]) / 255, blue: CGFloat(bytes[2]) / 255, alpha: 1)
        return (ns, G.hex(red: bytes[0], green: bytes[1], blue: bytes[2]))
    }
}
