import AppKit
import CaptureCore
import ScreenCaptureKit
import ThermoL10n

/// Thermo's own region picker for screenshots. Every display is frozen before the overlay appears,
/// so menus and hover states stay as they were when the shortcut was pressed. Hovering highlights
/// the window under the pointer (click takes it); dragging draws a region; the selection can then
/// be moved, resized from eight handles or nudged with the arrow keys, marked up, read with OCR,
/// and finished with one explicit output: copy, pin to the desktop or save.
@available(macOS 14, *)
@MainActor final class CaptureScreenshotSelector {
    enum Outcome { case cancelled, captured(CGImage, after: [CaptureAfterStep], text: String?), region(CaptureRegionSelector.Region) }
    /// `.screenshot` crops the frozen frame; `confirm` is what Enter and the primary button run
    /// (nil: copy the image). `.region` only reports where (long screenshots, recording).
    enum Purpose { case screenshot(confirm: [CaptureAfterStep]?), region(confirmTitle: String) }
    enum SaveResult { case saved(copyAfterSave: Bool), cancelled, failed(Error) }
    let purpose: Purpose
    /// Saves the marked selection while the selector is hidden; anything but success brings the
    /// same selection and marks back.
    var saveImage: ((CGImage) -> SaveResult)?
    private let captureDisplays: @MainActor () async throws -> [Frozen]
    init(purpose: Purpose = .screenshot(confirm: nil),
         captureDisplays: @escaping @MainActor () async throws -> [Frozen] = CaptureScreenshotSelector.freezeDisplays) {
        self.purpose = purpose; self.captureDisplays = captureDisplays
    }
    struct Frozen { let screen: NSScreen; let displayID: CGDirectDisplayID; let image: CGImage; let windows: [CGRect] }

    private var panels: [NSPanel] = []
    private var views: [SelectorView] = []
    private var completion: ((Result<Outcome, Error>) -> Void)?
    private var loading: Task<Void, Never>?
    private var displayObserver: NSObjectProtocol?

    func start(completion: @escaping (Result<Outcome, Error>) -> Void) {
        guard self.completion == nil else { return }
        self.completion = completion
        let captureDisplays = self.captureDisplays
        loading = Task { [weak self] in
            do {
                let frozen = try await captureDisplays()
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

    /// The panels sit above the save panel's level, so they step aside while it is open.
    private func save(_ image: CGImage, from panel: NSWindow?) {
        guard let saveImage else { NSSound.beep(); return }
        for panel in panels { panel.orderOut(nil) }
        let result = saveImage(image)
        // A display change may have cancelled the capture while the save panel was open.
        guard completion != nil else { return }
        switch result {
        case .saved(let copy): finish(.success(.captured(image, after: CaptureSelectionOutput.saved(copyAfterSave: copy).steps, text: nil)))
        case .cancelled: reveal(panel)
        case .failed(let error):
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.messageText = tr("Could not save the screenshot."); alert.informativeText = captureFailureMessage(error)
            alert.runModal()
            guard completion != nil else { return }
            reveal(panel)
        }
    }

    private func reveal(_ key: NSWindow?) {
        for panel in panels { panel.orderFrontRegardless() }
        NSApp.activate(ignoringOtherApps: true)
        let target = key ?? panels.first
        target?.makeKeyAndOrderFront(nil); target?.makeFirstResponder(target?.contentView)
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
            view.onSave = { [weak self, weak panel] image in self?.save(image, from: panel) }
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

/// Tool and output rows, laid out by CaptureSelectionGeometry so they wrap instead of leaving the screen.
private final class SelectorToolbar: NSView {
    var groups: [[NSView]] = [] {
        didSet { oldValue.joined().forEach { $0.removeFromSuperview() }; groups.joined().forEach { addSubview($0) } }
    }
    init() {
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var isFlipped: Bool { true }
    func fit(maxWidth: CGFloat) -> CGSize {
        let layout = CaptureSelectionGeometry.toolbarLayout(groups.map { $0.map(\.fittingSize) }, maxWidth: maxWidth)
        for (views, frames) in zip(groups, layout.frames) { for (view, frame) in zip(views, frames) { view.frame = frame } }
        return layout.size
    }
}

/// Esc inside the recognised text goes back to the screenshot instead of completing a word.
private final class RecognitionTextView: NSTextView {
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Recognised text over the selection: edit, then copy and finish; failures keep retry and back.
@available(macOS 14, *)
private final class RecognitionCard: NSView {
    enum State { case working, text(String), failed(String) }
    var onBack: (() -> Void)?
    var onRetry: (() -> Void)?
    var onCopy: ((String) -> Void)?
    let textView = RecognitionTextView(frame: CGRect(x: 0, y: 0, width: 352, height: 160))
    private let status = NSTextField(wrappingLabelWithString: "")
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private var retryButton: NSButton!
    private var copyButton: NSButton!

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 380, height: 120))
        wantsLayer = true; layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.97).cgColor
        let title = NSTextField(labelWithString: tr("Recognize text")); title.font = .boldSystemFont(ofSize: 13)
        textView.isRichText = false; textView.font = .systemFont(ofSize: 13); textView.allowsUndo = true
        textView.isVerticallyResizable = true; textView.autoresizingMask = [.width]; textView.textContainer?.widthTracksTextView = true
        textView.minSize = CGSize(width: 0, height: 160); textView.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.onEscape = { [weak self] in self?.onBack?() }
        scroll.documentView = textView; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let back = NSButton(title: tr("Back to screenshot"), target: self, action: #selector(goBack))
        retryButton = NSButton(title: tr("Try again"), target: self, action: #selector(tryAgain))
        copyButton = NSButton(title: tr("Copy text and finish"), target: self, action: #selector(copyText))
        copyButton.bezelColor = .controlAccentColor
        let buttons = NSStackView(); buttons.orientation = .horizontal; buttons.spacing = 8
        buttons.addView(back, in: .leading); buttons.addView(retryButton, in: .trailing); buttons.addView(copyButton, in: .trailing)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        for view in [title, status, scroll, buttons] { stack.addArrangedSubview(view) }
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            scroll.widthAnchor.constraint(equalToConstant: 352), scroll.heightAnchor.constraint(equalToConstant: 160),
            status.widthAnchor.constraint(equalTo: scroll.widthAnchor), buttons.widthAnchor.constraint(equalTo: scroll.widthAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ state: State) {
        switch state {
        case .working: status.stringValue = tr("Recognizing text and barcodes…")
        case .text(let text): textView.string = text
        case .failed(let message): status.stringValue = message
        }
        if case .text = state { status.isHidden = true; scroll.isHidden = false } else { status.isHidden = false; scroll.isHidden = true }
        if case .failed = state { retryButton.isHidden = false } else { retryButton.isHidden = true }
        if case .text = state { copyButton.isHidden = false } else { copyButton.isHidden = true }
        layoutSubtreeIfNeeded()
        setFrameSize(CGSize(width: 380, height: stack.fittingSize.height))
    }

    @objc private func goBack() { onBack?() }
    @objc private func tryAgain() { onRetry?() }
    @objc private func copyText() {
        let text = textView.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { NSSound.beep(); return }
        onCopy?(text)
    }
}

@available(macOS 14, *)
private final class SelectorView: NSView, NSTextFieldDelegate {
    private typealias G = CaptureSelectionGeometry
    private enum Drag { case none, drawing(start: CGPoint), moving(grab: CGPoint, original: CGRect), resizing(CaptureSelectionHandle) }

    let frozen: CaptureScreenshotSelector.Frozen
    let purpose: CaptureScreenshotSelector.Purpose
    var onFinish: ((CaptureScreenshotSelector.Outcome) -> Void)?
    var onSave: ((CGImage) -> Void)?
    var onBeginSelection: (() -> Void)?

    private let scale: CGFloat
    private var hovered: CGRect?
    private var selection: CGRect?
    private var drag: Drag = .none
    private var mouseDownPoint: CGPoint?
    private var drawing = false
    private var pointer: CGPoint?
    private let toolbar = SelectorToolbar()
    /// Marks drawn on the selection before an output, in view coordinates (display points).
    private var tool: CaptureTool?
    private var markup = CaptureSelectionMarkup()
    private var draft: CaptureSelectionMark?
    private var textEntry: NSTextField?
    private var recognition: RecognitionCard?
    private var recognitionTask: Task<Void, Never>?
    private var toolButtons: [CaptureTool: NSButton] = [:]
    private var undoButton: NSButton?
    private var redoButton: NSButton?
    /// Typed text is 18 points on screen, the size CaptureDocument draws for the mark's width.
    private static let textPointSize: CGFloat = 18
    static let markTools: [(CaptureTool, String, String, String)] = [
        (.rectangle, "rectangle", "Rectangle", "r"), (.arrow, "arrow.up.right", "Arrow", "a"),
        (.text, "textformat", "Text", "t"), (.mosaic, "checkerboard.rectangle", "Mosaic", "m"),
        (.number, "1.circle", "Sequence number", "n")]

    init(frame: NSRect, frozen: CaptureScreenshotSelector.Frozen, purpose: CaptureScreenshotSelector.Purpose) {
        self.frozen = frozen; self.purpose = purpose
        scale = frame.width > 0 ? CGFloat(frozen.image.width) / frame.width : frozen.screen.backingScaleFactor
        super.init(frame: frame)
        setAccessibilityLabel(tr("Select a screenshot region") + " · " + frozen.screen.localizedName)
        func iconButton(_ symbol: String, _ title: String, _ key: String, _ action: Selector) -> NSButton {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tr(title)) ?? NSImage(), target: self, action: action)
            button.bezelStyle = .texturedRounded; button.toolTip = tr(title) + " (" + key + ")"
            return button
        }
        func textButton(_ title: String, _ action: Selector) -> NSButton {
            let button = NSButton(title: title, target: self, action: action); button.bezelStyle = .rounded
            return button
        }
        var tools: [NSView] = [], outputs: [NSView] = [textButton(tr("Cancel"), #selector(cancelSelection))]
        switch purpose {
        case .screenshot(let confirm):
            for (tool, symbol, title, key) in Self.markTools {
                let button = iconButton(symbol, title, key.uppercased(), #selector(pickTool(_:)))
                button.setButtonType(.pushOnPushOff); button.identifier = NSUserInterfaceItemIdentifier(tool.rawValue)
                toolButtons[tool] = button; tools.append(button)
            }
            let undo = iconButton("arrow.uturn.backward", "Undo", "⌘Z", #selector(undoMark))
            let redo = iconButton("arrow.uturn.forward", "Redo", "⇧⌘Z", #selector(redoMark))
            let ocr = NSButton(title: tr("Recognize text"), image: NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: nil) ?? NSImage(),
                               target: self, action: #selector(recognizeSelection))
            ocr.bezelStyle = .texturedRounded; ocr.imagePosition = .imageLeading
            undoButton = undo; redoButton = redo; tools += [undo, redo, ocr]
            let steps = CaptureSelectionOutput.primary(confirm: confirm).steps
            // No key equivalent: Return must stay with a text field while typing.
            let primary = textButton(steps == [.copyImage] ? tr("Copy image") : tr("Done"), #selector(confirmSelection))
            primary.bezelColor = .controlAccentColor; primary.toolTip = "↩"
            let save = textButton(tr("Save"), #selector(saveSelection)); save.toolTip = "⌘S"
            outputs += [textButton(tr("Pin to desktop"), #selector(pinSelection)), save, primary]
        case .region(let title):
            outputs.append(textButton(title, #selector(confirmSelection)))
        }
        toolbar.groups = [tools, outputs]
        updateHistoryButtons()
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
        endTextEntry(commit: false); closeRecognition()
        selection = nil; drag = .none; toolbar.isHidden = true
        markup = CaptureSelectionMarkup(); draft = nil; setTool(nil); updateHistoryButtons(); needsDisplay = true
    }

    private func setTool(_ next: CaptureTool?) {
        tool = next
        for (key, button) in toolButtons { button.state = key == next ? .on : .off }
        needsDisplay = true
    }
    @objc private func pickTool(_ sender: NSButton) {
        endTextEntry(commit: true)
        let picked = sender.identifier.flatMap { CaptureTool(rawValue: $0.rawValue) }
        setTool(picked == tool ? nil : picked)
        window?.makeFirstResponder(self)
    }
    private func add(_ mark: CaptureSelectionMark) { markup.add(mark); updateHistoryButtons(); needsDisplay = true }
    @objc private func undoMark() { endTextEntry(commit: true); markup.undo(); updateHistoryButtons(); needsDisplay = true }
    @objc private func redoMark() { markup.redo(); updateHistoryButtons(); needsDisplay = true }
    private func updateHistoryButtons() { undoButton?.isEnabled = markup.canUndo; redoButton?.isEnabled = markup.canRedo }

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

    // MARK: Text entry

    private func beginTextEntry(at point: CGPoint, in selection: CGRect) {
        let field = NSTextField(string: "")
        field.font = .systemFont(ofSize: Self.textPointSize); field.textColor = .systemRed
        field.isBordered = false; field.drawsBackground = true; field.backgroundColor = NSColor.white.withAlphaComponent(0.7)
        field.focusRingType = .none; field.placeholderString = tr("Text"); field.delegate = self
        let height = field.intrinsicContentSize.height
        field.frame = CGRect(x: point.x, y: point.y - height / 2, width: max(120, selection.maxX - point.x), height: height)
        addSubview(field); textEntry = field
        window?.makeFirstResponder(field)
    }

    /// Typed text becomes a mark whose baseline box sits where the field showed it.
    private func endTextEntry(commit: Bool) {
        guard let field = textEntry else { return }
        textEntry = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        window?.makeFirstResponder(self)
        field.removeFromSuperview()
        if commit, !text.isEmpty { add(CaptureSelectionMark(tool: .text, points: [CGPoint(x: field.frame.minX + 2, y: field.frame.maxY)], text: text)) }
        needsDisplay = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { endTextEntry(commit: true); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { endTextEntry(commit: false); return true }
        return false
    }
    func controlTextDidEndEditing(_ obj: Notification) { endTextEntry(commit: true) }

    // MARK: Mouse

    override func mouseEntered(with event: NSEvent) {
        guard recognition == nil, textEntry == nil else { return }
        window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(self)
        updateHover(convert(event.locationInWindow, from: nil))
    }
    override func mouseExited(with event: NSEvent) { pointer = nil; if selection == nil { hovered = nil }; needsDisplay = true }
    override func mouseMoved(with event: NSEvent) { updateHover(convert(event.locationInWindow, from: nil)); updateCursor() }
    override func cursorUpdate(with event: NSEvent) { updateCursor() }

    override func mouseDown(with event: NSEvent) {
        guard recognition == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        endTextEntry(commit: true)
        pointer = point; mouseDownPoint = point
        if let tool, let selection {
            // With a tool picked, clicks and drags inside the selection mark it; the selection stays put.
            guard selection.contains(point) else { return }
            switch tool {
            case .text: beginTextEntry(at: point, in: selection)
            case .number: if event.clickCount == 1 { add(CaptureSelectionMark(tool: .number, points: [point], text: String(markup.nextNumber))) }
            default: draft = CaptureSelectionMark(tool: tool, points: [point])
            }
            return
        }
        if event.clickCount == 2, let selection, selection.contains(point) { confirmSelection(); return }
        if let selection {
            if let handle = G.handle(at: point, of: selection) { drag = .resizing(handle); return }
            if selection.contains(point) { drag = .moving(grab: point, original: selection); return }
        }
        drag = .drawing(start: point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard recognition == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        pointer = point
        if var mark = draft, let selection {
            let clamped = CGPoint(x: min(max(point.x, selection.minX), selection.maxX), y: min(max(point.y, selection.minY), selection.maxY))
            mark.points = [mark.points[0], clamped]
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
        guard recognition == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let mark = draft {
            draft = nil
            let a = mark.points.first!, b = mark.points.last!
            if hypot(b.x - a.x, b.y - a.y) >= 3 { add(mark) }
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
        guard recognition == nil else { return }
        if textEntry != nil { endTextEntry(commit: false); return }
        if tool != nil { setTool(nil); return }
        if selection != nil { clearSelection(); updateHover(convert(event.locationInWindow, from: nil)) } else { onFinish?(.cancelled) }
    }

    private func updateCursor() {
        guard recognition == nil, let pointer, let selection, case .none = drag else { NSCursor.crosshair.set(); return }
        if let tool {
            (tool == .text && selection.contains(pointer) ? NSCursor.iBeam : NSCursor.crosshair).set(); return
        }
        if let handle = G.handle(at: pointer, of: selection) {
            switch handle {
            case .left, .right: NSCursor.resizeLeftRight.set()
            case .top, .bottom: NSCursor.resizeUpDown.set()
            default: NSCursor.crosshair.set()
            }
        } else if selection.contains(pointer) { NSCursor.openHand.set() } else { NSCursor.crosshair.set() }
    }

    // MARK: Keyboard

    /// Command shortcuts only while the selector itself has focus, so typing a mark or editing OCR
    /// text keeps its own undo, copy and save keys.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, recognition == nil, case .screenshot = purpose else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags == [.command], key == "z" { undoMark() }
        else if flags == [.command, .shift], key == "z" { redoMark() }
        else if flags == [.command], key == "s" { saveSelection() }
        else if flags == [.command], key == "c" { copySelection() }
        else { return super.performKeyEquivalent(with: event) }
        return true
    }

    override func keyDown(with event: NSEvent) {
        if recognition != nil { if event.keyCode == 53 { closeRecognition() }; return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let step: CGFloat = flags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 53: onFinish?(.cancelled)                                   // Esc
        case 36, 76: confirmSelection()                                  // Return, Enter
        case 123, 124, 125, 126:                                         // arrows
            guard var rect = selection, markup.marks.isEmpty, tool == nil else { return }
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
            if flags.isEmpty, selection != nil, case .screenshot = purpose, let pick = Self.markTools.first(where: { $0.3 == key }) { setTool(tool == pick.0 ? nil : pick.0) }
            else if flags.contains(.command), key == "a" { onBeginSelection?(); selection = bounds; hovered = nil; layoutToolbar(); needsDisplay = true }
            else if flags.isEmpty, key == "c", let pointer, let hex = color(at: pointer)?.hex {
                // Copy the color under the pointer, as a colour picker would, then close.
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(hex, forType: .string)
                onFinish?(.cancelled)
            } else { super.keyDown(with: event) }
        }
    }

    // MARK: Outputs

    @objc private func cancelSelection() { onFinish?(.cancelled) }
    @objc private func copySelection() { output(.copyImage) }
    @objc private func pinSelection() { output(.pin) }
    @objc private func confirmSelection() {
        switch purpose {
        case .screenshot(let confirm): output(.primary(confirm: confirm))
        case .region:
            // Recording and long screenshots need at least 32 points each way (see Region.validate).
            guard let rect = target?.integral.intersection(bounds), rect.width >= 32, rect.height >= 32 else { NSSound.beep(); return }
            onFinish?(.region(CaptureRegionSelector.Region(displayID: frozen.displayID, rect: rect, scale: frozen.screen.backingScaleFactor,
                                                           selectedDisplaySize: frozen.screen.frame.size)))
        }
    }
    @objc private func saveSelection() {
        endTextEntry(commit: true)
        guard let image = renderedSelection() else { NSSound.beep(); return }
        onSave?(image)
    }

    private func output(_ choice: CaptureSelectionOutput) {
        endTextEntry(commit: true)
        guard let image = renderedSelection() else { NSSound.beep(); return }
        onFinish?(.captured(image, after: choice.steps, text: nil))
    }

    private func pixels(of rect: CGRect) -> CGRect? {
        G.pixelRect(rect, scale: scale, imageSize: CGSize(width: frozen.image.width, height: frozen.image.height))
    }

    /// The selected pixels with this capture's marks burnt in.
    private func renderedSelection() -> CGImage? {
        guard let rect = target, let pixels = pixels(of: rect), let cropped = frozen.image.cropping(to: pixels) else { return nil }
        do { return try markup.rendered(onto: cropped, crop: pixels, scale: scale) ?? cropped } catch { return nil }
    }

    // MARK: Text recognition

    @objc private func recognizeSelection() {
        endTextEntry(commit: true)
        guard recognition == nil, let selection, let image = renderedSelection() else { NSSound.beep(); return }
        setTool(nil); draft = nil
        let card = RecognitionCard()
        card.onBack = { [weak self] in self?.closeRecognition() }
        card.onRetry = { [weak self] in self?.recognize(image) }
        card.onCopy = { [weak self] text in self?.onFinish?(.captured(image, after: CaptureSelectionOutput.copyText.steps, text: text)) }
        recognition = card; toolbar.isHidden = true
        addSubview(card)
        recognize(image)
        placeRecognition(over: selection)
        needsDisplay = true
    }

    private func recognize(_ image: CGImage) {
        guard let card = recognition else { return }
        recognitionTask?.cancel()
        card.show(.working); window?.makeFirstResponder(self)
        if let selection { placeRecognition(over: selection) }
        recognitionTask = Task { [weak self] in
            let result: Result<String, Error>
            do { result = .success(try await CaptureSaveModel.recognizeText(image)) } catch { result = .failure(error) }
            guard let self, !Task.isCancelled, self.recognition === card else { return }
            switch result {
            case .success(let text) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                card.show(.text(text)); self.window?.makeFirstResponder(card.textView)
            case .success: card.show(.failed(tr("No text or barcode found.")))
            case .failure(let error): card.show(.failed(captureFailureMessage(error)))
            }
            if let selection = self.selection { self.placeRecognition(over: selection) }
        }
    }

    private func placeRecognition(over selection: CGRect) {
        guard let card = recognition else { return }
        let size = card.frame.size
        let x = min(max(selection.midX - size.width / 2, bounds.minX + 8), bounds.maxX - size.width - 8)
        let y = min(max(selection.midY - size.height / 2, bounds.minY + 8), bounds.maxY - size.height - 8)
        card.setFrameOrigin(CGPoint(x: x, y: y))
    }

    /// Back to the screenshot with its selection and marks untouched.
    private func closeRecognition() {
        guard let card = recognition else { return }
        recognitionTask?.cancel(); recognitionTask = nil
        recognition = nil; card.removeFromSuperview()
        window?.makeFirstResponder(self); layoutToolbar(); needsDisplay = true
    }

    // MARK: Drawing

    private func layoutToolbar() {
        guard let selection, case .none = drag, recognition == nil else { toolbar.isHidden = true; return }
        toolbar.isHidden = false
        let size = toolbar.fit(maxWidth: bounds.width - 8)
        toolbar.frame = CGRect(origin: G.toolbarOrigin(size: size, selection: selection, bounds: bounds), size: size)
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
        drawMarks(in: context)
        if let pointer, showsMagnifier { drawMagnifier(at: pointer, in: context) }
    }

    /// The preview draws each mark with CaptureDocument in the selection's pixel space, so what is
    /// on screen is what the copied or saved image gets.
    private func drawMarks(in context: CGContext) {
        let marks = markup.layered + (draft.map { [$0] } ?? [])
        guard !marks.isEmpty, let selection, let pixels = pixels(of: selection), let base = frozen.image.cropping(to: pixels) else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.clip(to: selection)
        context.translateBy(x: pixels.minX / scale, y: pixels.maxY / scale); context.scaleBy(x: 1 / scale, y: -1 / scale)
        for mark in marks { try? CaptureDocument.draw(CaptureSelectionMarkup.annotation(mark, scale: scale, crop: pixels), in: context, base: base) }
    }

    private var showsMagnifier: Bool {
        if tool != nil || recognition != nil || textEntry != nil { return false }
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
