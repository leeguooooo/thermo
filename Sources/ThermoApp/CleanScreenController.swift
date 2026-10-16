import AppKit
import ApplicationServices
import SwiftUI
import ThermoL10n

@MainActor protocol CleanScreenDriver: AnyObject {
    var hasAccessibility: Bool { get }
    func begin(_ model: CleanScreenModel) throws
    func end()
}

@MainActor final class CleanScreenModel: ObservableObject {
    enum Interruption: String {
        case tapTimeout, tapDisabled, focus, display, sleep, session, termination
        var message: String {
            switch self {
            case .tapTimeout, .tapDisabled: return tr("macOS disabled keyboard interception. Clean Screen has stopped.")
            case .focus: return tr("Thermo lost focus. Clean Screen has stopped.")
            case .display: return tr("The display configuration changed. Clean Screen has stopped.")
            case .sleep: return tr("The Mac is going to sleep. Clean Screen has stopped.")
            case .session: return tr("The login session changed. Clean Screen has stopped.")
            case .termination: return tr("Thermo is quitting. Clean Screen has stopped.")
            }
        }
    }
    static let shared = CleanScreenModel()
    @Published private(set) var session: CleanScreenSession?
    @Published private(set) var now: TimeInterval = 0
    @Published private(set) var hasAccessibility = false
    @Published private(set) var issue: String?
    private(set) var interruption: Interruption?
    private(set) var finished: CleanScreenSession.Finish?
    private let driver: CleanScreenDriver
    private let clock: () -> TimeInterval
    var active: Bool { session != nil }
    init(driver: CleanScreenDriver? = nil, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.driver = driver ?? NativeCleanScreenDriver(); self.clock = clock
    }
    func refreshPermission() { hasAccessibility = driver.hasAccessibility }
    func start(_ duration: CleanScreenDuration) {
        guard !active else { return }
        refreshPermission()
        guard hasAccessibility else { issue = tr("Enable Accessibility for Thermo before starting Clean Screen."); return }
        issue = nil; interruption = nil; finished = nil; now = clock(); session = .init(started: now, duration: duration)
        do { try driver.begin(self) }
        catch { session = nil; driver.end(); issue = tr("Keyboard interception could not start. Clean Screen was not enabled.") }
    }
    func tick() {
        guard active else { return }
        now = clock()
        if let finish = session?.finish(now) { stop(completed: finish) }
    }
    func key(_ code: Int64, down: Bool, repeated: Bool, modified: Bool) {
        guard active, code == 53 else { return }
        session?.key(code, down: down, repeated: repeated, modified: modified, now: clock())
    }
    func modifiersChanged() {
        guard session?.escapeStarted != nil else { return }
        session?.modifiersChanged()
    }
    func holdExit(_ pressed: Bool) { session?.pointer(pressed, now: clock()) }
    func stop(interruption: Interruption? = nil, completed: CleanScreenSession.Finish? = nil) {
        guard active else { return }
        self.interruption = interruption
        finished = completed
        session = nil
        // The driver releases interception before closing any overlay.
        driver.end()
        if let interruption { issue = interruption.message }
    }
    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

private final class CleanScreenWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor private final class NativeCleanScreenDriver: CleanScreenDriver {
    var hasAccessibility: Bool { AXIsProcessTrusted() }
    private var taps: [CFMachPort] = []
    private var sources: [CFRunLoopSource] = []
    private var timer: Timer?
    private var localMonitor: Any?
    private var windows: [NSWindow] = []
    private var observations: [(NotificationCenter, NSObjectProtocol)] = []
    private weak var model: CleanScreenModel?
    private weak var previousWindow: NSWindow?
    private enum Failure: Error { case unavailable }
    func begin(_ model: CleanScreenModel) throws {
        guard let displays = Self.displayConfiguration(), taps.isEmpty, windows.isEmpty, hasAccessibility else { throw Failure.unavailable }
        let frames = displays.map(\.frame)
        self.model = model; previousWindow = NSApp?.keyWindow?.sheetParent ?? NSApp?.keyWindow
        // Session tap: never use the root-only HID tap. System-defined events cover
        // media keys delivered to this stream; hardware/OS paths still need device acceptance.
        // Keep ordinary keys in their own tap. If macOS strips denied key events,
        // that tap's mask becomes empty and creation fails instead of accepting a media-only filter.
        let groups: [[UInt32]] = [[CGEventType.keyDown.rawValue, CGEventType.keyUp.rawValue],
                                 [CGEventType.flagsChanged.rawValue, UInt32(NSEvent.EventType.systemDefined.rawValue)]]
        for types in groups {
            let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1) }
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask, callback: { _, type, event, context in
                    guard let context else { return Unmanaged.passUnretained(event) }
                    return MainActor.assumeIsolated {
                        let driver = Unmanaged<NativeCleanScreenDriver>.fromOpaque(context).takeUnretainedValue()
                        guard let model = driver.model, model.active else { return Unmanaged.passUnretained(event) }
                        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                            model.stop(interruption: type == .tapDisabledByTimeout ? .tapTimeout : .tapDisabled)
                            return Unmanaged.passUnretained(event)
                        }
                        if type == .keyDown || type == .keyUp {
                            let flags = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
                            model.key(event.getIntegerValueField(.keyboardEventKeycode), down: type == .keyDown,
                                      repeated: event.getIntegerValueField(.keyboardEventAutorepeat) != 0, modified: !flags.isEmpty)
                        } else if type == .flagsChanged { model.modifiersChanged() }
                        return nil
                    }
                }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { throw Failure.unavailable }
            taps.append(tap)
            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { throw Failure.unavailable }
            sources.append(source)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            guard CGEvent.tapIsEnabled(tap: tap) else { throw Failure.unavailable }
        }
        // App-directed synthetic events can bypass a session tap. Consume the
        // AppKit route too; the global taps remain required for physical/system input.
        guard let monitor = NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.keyUp,.flagsChanged,.systemDefined], handler:{ [weak model] event in
            MainActor.assumeIsolated {
                guard let model, model.active else { return event }
                if event.type == .keyDown || event.type == .keyUp {
                    let flags = event.modifierFlags.intersection([.command,.control,.option,.shift])
                    model.key(Int64(event.keyCode),down:event.type == .keyDown,repeated:event.isARepeat,modified:!flags.isEmpty)
                } else if event.type == .flagsChanged { model.modifiersChanged() }
                return nil
            }
        }) else { throw Failure.unavailable }
        localMonitor = monitor
        for frame in frames {
            let window = CleanScreenWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.backgroundColor = .black; window.isOpaque = true
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.contentView = NSHostingView(rootView: CleanScreenOverlay(model: model))
            windows.append(window); window.orderFrontRegardless()
        }
        guard Self.displayConfiguration() == displays else { throw Failure.unavailable }
        NSApp?.activate(ignoringOtherApps: true); windows.first?.makeKeyAndOrderFront(nil)
        observe(NSApplication.didResignActiveNotification, center: .default, cause: .focus)
        let displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak model] _ in
            MainActor.assumeIsolated {
                if Self.displayConfiguration() != displays { model?.stop(interruption: .display) }
            }
        }
        observations.append((.default, displayObserver))
        observe(NSApplication.willTerminateNotification, center: .default, cause: .termination)
        observe(NSWorkspace.willSleepNotification, center: NSWorkspace.shared.notificationCenter, cause: .sleep)
        observe(NSWorkspace.sessionDidResignActiveNotification, center: NSWorkspace.shared.notificationCenter, cause: .session)
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak model] _ in
            MainActor.assumeIsolated { model?.tick() }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private static func displayConfiguration() -> [CleanScreenDisplay]? {
        var displays: [CleanScreenDisplay] = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  number.int64Value > 0, number.uint64Value <= UInt64(UInt32.max) else { return nil }
            displays.append(.init(id:number.uint32Value,frame:screen.frame,scale:Double(screen.backingScaleFactor)))
        }
        return CleanScreenDisplay.normalized(displays)
    }
    private func observe(_ name: Notification.Name, center: NotificationCenter, cause: CleanScreenModel.Interruption) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak model] _ in
            MainActor.assumeIsolated { model?.stop(interruption: cause) }
        }
        observations.append((center, observer))
    }
    func end() {
        for tap in taps { CGEvent.tapEnable(tap: tap, enable: false) }
        for source in sources { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        for tap in taps { CFMachPortInvalidate(tap) }
        sources = []; taps = []; model = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
        timer?.invalidate(); timer = nil
        for (center, observer) in observations { center.removeObserver(observer) }; observations = []
        let old = windows; windows = []
        for window in old { window.close() }
        if NSApp?.isActive == true, previousWindow?.isVisible == true { previousWindow?.makeKeyAndOrderFront(nil) }
        previousWindow = nil
    }
}
