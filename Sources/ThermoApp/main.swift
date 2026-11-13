import AppKit
import os
import UserNotifications
import SwiftUI
import AgentDoctor
import CleanKit
import ThermoKit
import ThermoL10n

/// The menu bar panel is sized once per show for the screen it opens on. SwiftUI changes while it is open
/// must not resize it, or AppKit shifts it across the menu bar and onto the neighbouring display.
@MainActor enum PanelPopover {
    static func host(_ monitor: Monitor) -> NSHostingController<PopoverView> {
        let host = NSHostingController(rootView: PopoverView(monitor: monitor))
        host.sizingOptions = []
        return host
    }
    static func size(_ popover: NSPopover, visibleHeight: CGFloat) {
        // Asked of SwiftUI directly: with sizing options off the hosting view no longer reports a fitting size.
        guard let host = popover.contentViewController as? NSHostingController<PopoverView> else { return }
        let ideal = host.sizeThatFits(in: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        // Leave room for the arrow and a margin; the panel's scroll area takes up the rest.
        popover.contentSize = NSSize(width: ideal.width, height: min(ideal.height, visibleHeight - 24))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, UNUserNotificationCenterDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var monitor: Monitor { AppModels.shared.monitor }
    private var lastTitle: String?
    private var menuFreshnessTimer: Timer?
    private var menuPreferences = MenuBarPreferences()
    private var menuValidAfter = Date.distantPast

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        CaptureWorkspace.shared.terminationReply(AppExitGuard.reply())
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.register()
        AppInstallationMonitor.shared.start()
        AppControlHost.shared.start()
        ModuleCenter.shared.start()
        CleanScreenShortcutModel.enableLive()
        LocalSearchShortcut.shared.activate()
        CaptureWorkspace.shared.activate()
        LocalSearchModel.shared.start()
        if CommandLine.arguments.contains("--search") { DispatchQueue.main.async { LocalSearchPanel.shared.show() } }
        BatteryCareModel.shared.restoreSavedPreference()
        _ = AppModels.shared.updates  // Sparkle starts checking with the app
        // Slowdown history and alerts, in the background whether or not the panel is open.
        PulseRecorder.shared.start()
        TabAutomation.shared.start()
        YunXClipboardPrompt.shared.refresh()
        Task { await YunXChromeUseSetup.shared.offerOnLaunch() }
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate = self }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: "Thermo")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.action = #selector(toggle)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = PanelPopover.host(monitor)
        IdleAwakeModel.shared.onStateChange = { [weak self] in
            guard let self else { return }
            self.updateTitle(self.monitor.latest)
        }
        FocusStatusItem.shared.start()
        FocusTimerModel.shared.launch()
        // Hidden panel curves do not keep resource readers running.
        PanelModel.shared.setActive(false)

        applyDockPreference()
        installMainMenu()
        // Keep existing shortcut priority and prepare recovery UI before optional presets.
        MenuBarManager.shared.start()
        // macOS hides status items that do not fit next to the notch, without telling anyone.
        // Check once the item has been laid out; if nobody can see it, open the panel ourselves.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.statusItemHidden() else { return }
            self.monitor.iconHidden = true
            self.showPanel()
        }

        monitor.onUpdate = { [weak self] s in self?.updateTitle(s) }
        monitor.onMenuUpdate = { [weak self] in
            guard let self else { return }
            self.updateTitle(self.monitor.latest)
        }
        menuPreferences = MenuBarPreferences.read()
        updateTitle(nil)
        // Expire stale readings even if the sampling queue is delayed or unavailable.
        menuFreshnessTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let hidden = self.statusItemHidden()
                if self.monitor.iconHidden != hidden { self.monitor.iconHidden = hidden }
                self.updateTitle(self.monitor.latest)
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.menuValidAfter = Date()
                self?.monitor.resetMenuBaselines()
                self?.monitor.reschedule()
                PanelModel.shared.resetBaselines()
            }
        }
        // `open Thermo.app --args --install-helper`: start helper registration right away (setup/QA).
        if CommandLine.arguments.contains("--install-helper") { monitor.installHelper() }
        // `thermo settings KEY VALUE` writes the same defaults from another process.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("dev.thermo.settingsChanged"), object: nil, queue: .main) { [weak self] _ in
            UserDefaults.standard.synchronize()
            Settings.normalize()
            L10n.apply(preference: UserDefaults.standard.string(forKey: L10n.defaultsKey))
            MainActor.assumeIsolated {
                self?.monitor.reschedule()
                self?.applyDockPreference()
                self?.applyMenuPreferences()
            }
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Settings.normalize()
            MainActor.assumeIsolated {
                self?.applyMenuPreferences()
                self?.applyDockPreference()
            }
        }
    }

    /// A slowdown notification was clicked: open the panel on the Overview, pointing at the program.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let program = response.notification.request.content.userInfo["program"] as? String
        DispatchQueue.main.async {
            PulseRecorder.shared.highlighted = (program?.isEmpty ?? true) ? nil : program
            NotificationCenter.default.post(name: PulseRecorder.showProgram, object: nil)
            self.showPanel()
        }
        done()
    }

    /// Show notifications even while Thermo is the active app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    /// Clicking the Dock icon (or opening Thermo.app again) opens the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindow.show()
        return false
    }

    private func applyDockPreference() {
        let policy: NSApplication.ActivationPolicy = UserDefaults.standard.bool(forKey: Settings.showInDock) ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    /// With a Dock icon the app also has a menu bar; keep it to the essentials.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: tr("Open Console"), action: #selector(openFromMenu), keyEquivalent: "o").target = self
        appMenu.addItem(withTitle: tr("Search apps and files"), action: #selector(openSearchFromMenu), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: tr("Capture screen…"), action: #selector(captureFromMenu), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: tr("Pin clipboard"), action: #selector(pinFromMenu), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: tr("Open image…"), action: #selector(openImageFromMenu), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: tr("Scrolling capture…"), action: #selector(scrollCaptureFromMenu), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: tr("Record screen…"), action: #selector(recordScreenFromMenu), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: tr("Recording drafts…"), action: #selector(recordingDraftsFromMenu), keyEquivalent: "").target = self
        let panelItem = appMenu.addItem(withTitle: tr("Open Menu Panel"), action: #selector(openPanelFromMenu), keyEquivalent: "p")
        panelItem.target = self
        panelItem.keyEquivalentModifierMask = [.command, .shift]
        appMenu.addItem(withTitle: tr("Save and close background tabs"), action: #selector(archiveTabsFromMenu), keyEquivalent: "s").target = self
        appMenu.items.last?.keyEquivalentModifierMask = [.command, .shift]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("Hide Thermo"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: tr("Quit Thermo"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = main
        installStandardMenus()
    }

    @objc private func openSearchFromMenu() { LocalSearchPanel.shared.show() }
    @objc private func captureFromMenu() { CaptureWorkspace.shared.capture() }
    @objc private func pinFromMenu() { CaptureWorkspace.shared.pinClipboard() }
    @objc private func openImageFromMenu() { CaptureWorkspace.shared.importImage() }
    @objc private func scrollCaptureFromMenu() { CaptureWorkspace.shared.captureScrolling() }
    @objc private func recordScreenFromMenu() { CaptureWorkspace.shared.recordScreen() }
    @objc private func recordingDraftsFromMenu() { CaptureWorkspace.shared.recordScreen(draftsOnly:true) }

    @objc fileprivate func archiveTabsFromMenu() { TabQuickAction.request() }

    @objc fileprivate func openFromMenu() { MainWindow.show() }

    private var panelNavigationAllowed: Bool {
        NSApp.modalWindow == nil && MainWindow.window?.attachedSheet == nil &&
            (!popover.isShown || popover.contentViewController?.view.window?.attachedSheet == nil)
    }
    @objc fileprivate func openPanelFromMenu() {
        guard panelNavigationAllowed else { return }
        showPanel()
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action != #selector(openPanelFromMenu) || panelNavigationAllowed
    }

    /// The screen the panel opens on: the one holding the menu bar icon, or the one under the pointer
    /// when the icon is hidden. Never `NSScreen.main`, which follows the key window to another display.
    private func panelScreen(hidden: Bool) -> NSScreen {
        let iconWindow = statusItem?.button?.window
        let icon = hidden ? nil : iconWindow?.screen ?? NSScreen.screens.first { screen in iconWindow.map { screen.frame.intersects($0.frame) } ?? false }
        return icon ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// True when the status item sits in the notch gap or off every screen.
    private func statusItemHidden() -> Bool {
        guard let window = statusItem.button?.window else { return true }
        let f = window.frame
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(f) }) else { return true }
        if f.maxX <= screen.frame.minX || f.minX >= screen.frame.maxX || !window.isVisible { return true }
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            // The notch is the gap between the two usable top areas.
            let notch = (screen.frame.minX + left.maxX)...(screen.frame.minX + right.minX)
            if notch.contains(f.midX) { return true }
        }
        return false
    }

    /// Shows the panel under the menu bar icon, or under the top centre of the screen when the
    /// icon cannot be seen.
    private func showPanel() {
        NSApp.activate(ignoringOtherApps: true)
        let hidden = statusItemHidden()
        monitor.iconHidden = hidden
        if popover.isShown {
            if panelVisible { popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil); return }
            // Marked shown but its window is gone (closed behind our back when another app took
            // focus): reset it so this click actually brings the panel up.
            popover.close()
        }
        monitor.popoverOpen = true
        PanelModel.shared.setActive(true)
        let screen = panelScreen(hidden: hidden)
        PanelPopover.size(popover, visibleHeight: screen.visibleFrame.height)
        let present = { [self] in
            if let button = statusItem.button, !hidden {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            } else {
                let anchor = panelAnchor(on: screen)
                popover.show(relativeTo: anchor.contentView!.bounds, of: anchor.contentView!, preferredEdge: .minY)
            }
        }
        present()
        if !panelSpacesConfigured, let window = popover.contentViewController?.view.window {
            // The popover's window only exists once shown, so the very first showing after launch
            // still used the default Space behaviour (and isOnActiveSpace cannot be trusted for it).
            // Configure it now and show once more; later showings start out right.
            panelSpacesConfigured = true
            joinFrontSpace(window)
            popover.close(); present()
        }
        popover.contentViewController?.view.window?.orderFrontRegardless()
        popover.contentViewController?.view.window?.makeKey()
    }

    /// With a Dock icon Thermo is a regular app, and its popover window stays on the ordinary
    /// desktop Space: clicked from another app's full-screen Space it opened off-screen, so the icon
    /// looked dead. The window exists by now but is not on screen yet: let it join the front Space.
    func popoverWillShow(_ notification: Notification) {
        if let window = popover.contentViewController?.view.window { joinFrontSpace(window) }
    }
    private var panelSpacesConfigured = false
    private func joinFrontSpace(_ window: NSWindow) {
        window.collectionBehavior.remove(.moveToActiveSpace)
        window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
    }

    private var anchorWindow: NSWindow?

    /// An invisible 1×1 window just below the menu bar, centred, for the popover to hang from.
    private func panelAnchor(on screen: NSScreen) -> NSWindow {
        let top = screen.visibleFrame.maxY
        let w = anchorWindow ?? NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        w.setFrame(NSRect(x: screen.frame.midX, y: top - 1, width: 1, height: 1), display: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .statusBar
        w.ignoresMouseEvents = true
        w.orderFrontRegardless()
        anchorWindow = w
        return w
    }

    func applicationWillTerminate(_ notification: Notification) {
        MenuBarManager.shared.shutdown()
        LocalSearchShortcut.shared.shutdown()
        CaptureCLIHost.shared.cancelActive()
        CaptureWorkspace.shared.shutdown()
        LocalSearchModel.shared.stop()
        YunXDownloadModel.shared.shutdown()
        // Fan policies live in the helper and intentionally survive the app quitting.
    }

    @objc private func toggle() {
        let p = MenuBarPreferences.read()
        let action = NSApp.currentEvent?.type == .rightMouseUp ? p.right : p.left
        if action == .console { MainWindow.show(); return }
        if action == .menu {
            closeMenuPanel()
            // Shown under the item the native way, then detached so the next click toggles again.
            statusItem.menu = StatusMenu.shared.make(battery: monitor.snapshot?.battery != nil)
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }
        // Only a panel the user can see counts as open; a stale "shown" state would turn this click
        // into a close of an invisible panel, so nothing appears.
        if panelVisible { popover.performClose(nil) } else { showPanel() }
    }

    private var panelVisible: Bool {
        guard popover.isShown, let window = popover.contentViewController?.view.window else { return false }
        return window.isVisible && window.occlusionState.contains(.visible)
    }

    func closeMenuPanel() {
        if popover.isShown { popover.performClose(nil) }
    }

    /// Leaves a trace when the panel lands outside one screen, the case reported as a clipped, shifted panel.
    func popoverDidShow(_ notification: Notification) {
        guard let window = popover.contentViewController?.view.window else { return }
        let frame = window.frame
        if !NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(frame) }) {
            Logger(subsystem: "dev.thermo", category: "panel").error(
                "panel outside one screen: frame \(NSStringFromRect(frame), privacy: .public) screens \(NSScreen.screens.map { NSStringFromRect($0.frame) + "@" + String(describing: $0.backingScaleFactor) }.joined(separator: ", "), privacy: .public) iconHidden \(self.monitor.iconHidden, privacy: .public)")
        }
    }

    func popoverDidClose(_ notification: Notification) {
        monitor.popoverOpen = false
        PanelModel.shared.setActive(false)
    }

    private func applyMenuPreferences() {
        let next = MenuBarPreferences.read()
        if next != menuPreferences {
            menuPreferences = next
            menuValidAfter = Date()
            monitor.resetMenuBaselines()
            monitor.reschedule()
        }
        updateTitle(monitor.latest)
    }

    private func updateTitle(_ s: Snapshot?) {
        guard let button = statusItem.button else { return }
        let d = UserDefaults.standard
        // Redrawing the status item costs ~2 ms; skip it when nothing visible changed.
        let awake = IdleAwakeModel.shared.state
        let marker = awake.phase == .active ? "☕︎" : awake.phase == .ending ? "☕︎?" : awake.requested ? "☕︎⏸" : ""
        let display = MenuDisplay.make(preferences: MenuBarPreferences.read(), snapshot: s,
                                       live: monitor.menuLive, fahrenheit: d.bool(forKey: Settings.fahrenheit), marker: marker,
                                       sensorReadStarted: monitor.menuLive.sampled, validAfter: menuValidAfter)
        let title = display.text.isEmpty ? "" : " " + display.text
        // The first update can precede status-button layout. Do not render a
        // miniature first frame from its temporarily zero bounds.
        let imageHeight = min(20, max(16, button.bounds.height > 0 ? button.bounds.height - 4 : 20))
        let cacheKey = "\(display.stacked):\(display.showIcon):\(imageHeight):\(title)"
        if cacheKey != lastTitle {
            lastTitle = cacheKey
            if display.stacked {
                button.attributedTitle = NSAttributedString(string: "")
                button.imageScaling = .scaleNone
                button.image = MenuStackImage.make(text: display.text, showIcon: display.showIcon, height: imageHeight)
            } else {
                button.imageScaling = .scaleProportionallyDown
                button.image = display.showIcon ? NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: "Thermo") : nil
                button.image?.isTemplate = true
                button.attributedTitle = NSAttributedString(string: title, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                ])
            }
        }
        button.cell?.wraps = false
        button.cell?.usesSingleLineMode = true
        button.setAccessibilityLabel(display.tooltip)
        if button.toolTip != display.tooltip { button.toolTip = display.tooltip }
    }
}

/// Debug aid: `Thermo --render-preview DIR` writes the menu bar panel as a PNG and exits.
/// (The main window's pages: `Thermo --main --offscreen --page PAGE --snapshot PATH`.)
/// The shared search model, started and given a query, for the preview render.
@MainActor private func searchPreviewModel() -> LocalSearchModel {
    let model = LocalSearchModel.shared
    model.start()
    model.query = "th"
    return model
}

@MainActor func renderPreviews(to dir: String) {
    Settings.register()
    renderingPreview = true
    let monitor = AppModels.shared.monitor
    // ImageRenderer never fires onAppear; start the "why is it slow" sampler up front.
    SystemPulse.shared.start()
    PanelModel.shared.setActive(true)
    monitor.popoverOpen = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
        // The capture menu as a plain list (Buttons as rows, Dividers as rules), for reviewing its wording and groups.
        let m = ImageRenderer(content: VStack(alignment: .leading, spacing: 6) { CaptureMenuItems() }
            .buttonStyle(.plain).padding(16).frame(width: 300, alignment: .leading).background(Color(nsColor: .windowBackgroundColor)))
        m.scale = 2
        if let img = m.cgImage {
            try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("panel-capture-menu.png"))
        }
        // Each tool sheet the settings page opens, for reviewing them without opening windows on screen.
        let tools: [(String, AnyView)] = [
            // The panel itself, hosted like the sheets so its capture Menu draws as a real control.
            ("panel", AnyView(PopoverView(monitor: monitor).frame(width: 372))),
            ("tool-keep-awake", AnyView(IdleAwakePanel(model: IdleAwakeModel.shared))),
            ("tool-clean-screen", AnyView(CleanScreenSetupView(model: CleanScreenModel.shared))),
            ("tool-low-latency", AnyView(AWDLPanel(model: AWDLModel.shared))),
            ("tool-battery-care", AnyView(BatteryCarePanel(model: BatteryCareModel.shared))),
            ("tool-focus", AnyView(FocusPanel(model: FocusTimerModel.shared))),
            ("tool-menu-bar", AnyView(MenuBarManagerView(model: .shared).frame(width: 940, height: 740))),
            // The search panel at its window size, with a query so the result rows and footer show.
            ("tool-search", AnyView(LocalSearchView(model: searchPreviewModel()).frame(width: 680, height: 520))),
            // The shared confirmation, as three pages fill it.
            ("confirm-uninstall", AnyView(ConfirmSheet(title: tr("Uninstall %1$@?", "Example"),
                summary: tr("%1$@ and %2$@ of its files go to the Trash: %3$@ in all.", "Example", "3", "1.2 GB"), destructive: false,
                heading: tr("What will be moved to the Trash"),
                lines: ["/Applications/Example.app", "~/Library/Application Support/Example", "~/Library/Caches/com.example.app", "~/Library/Preferences/com.example.app.plist"],
                footnote: tr("You can put them back from the Trash. Moves are listed in ~/Library/Logs/Thermo/clean.log."),
                confirmTitle: tr("Move to Trash"), confirm: {}, cancel: {}))),
            ("confirm-agent-fix", AnyView(ConfirmSheet(title: tr("%1$@ — %2$@", tr("Remove job"), "com.example.agent"),
                summary: tr("Runs launchctl bootout, then moves the plist to the Trash."), destructive: true,
                heading: tr("What will run"), lines: ["launchctl bootout gui/501/com.example.agent", "mv ~/Library/LaunchAgents/com.example.agent.plist ~/.Trash/"],
                footnote: tr("Config files are copied to ~/Library/Application Support/Thermo/Backups before they change. Each step is logged to ~/Library/Logs/Thermo/fix.log."),
                confirmTitle: tr("Remove job"), confirm: {}, cancel: {}))),
            ("confirm-end-process", AnyView(ConfirmSheet(title: tr("End %1$@?", "node"), summary: tr("Ending it frees about %1$@.", "512 MB"), destructive: true,
                heading: tr("What will run"), lines: ["kill -TERM 41234  node dist/bin/codegraph.js"],
                footnote: tr("Thermo checks the process is still the same one before it stops it."), confirmTitle: tr("End"), confirm: {}, cancel: {}))),
        ]
        // ImageRenderer draws AppKit controls as placeholders; host each one in an offscreen window instead.
        var windows: [NSWindow] = []
        for (name, view) in tools {
            let host = NSHostingView(rootView: view.preferredColorScheme(.dark).background(Theme.canvas))
            let size = host.fittingSize
            let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: max(size.width, 420), height: max(size.height, 200)),
                             styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = host
            w.appearance = NSAppearance(named: .darkAqua)
            w.orderBack(nil)
            windows.append(w)
            // 2.6 s, not 2: the monitor samples every 2 s, and a capture on that tick catches the
            // numeric transitions mid-animation (ghosted digits in the picture).
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.6) { withExtendedLifetime(windows) {}; exit(0) }
    }
}

@MainActor
private final class PageMenuTarget: NSObject, NSMenuItemValidation {
    static let shared = PageMenuTarget()
    @objc func open(_ item: NSMenuItem) {
        guard MainWindow.window?.attachedSheet == nil, let page = item.representedObject as? MainPage else { return }
        MainWindow.show(page)
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool { MainWindow.window?.attachedSheet == nil }
}

/// AppKit routes text editing shortcuts through the menu even for SwiftUI text fields.
@MainActor func installStandardMenus() {
    let main = NSApp.mainMenu ?? NSMenu()
    NSApp.mainMenu = main
    for item in main.items where ["thermo.edit", "thermo.view", "thermo.window"].contains(item.identifier?.rawValue ?? "") {
        main.removeItem(item)
    }
    // The app menu belongs to the delegate; preserve its targets while relabeling it.
    for item in main.items.first?.submenu?.items ?? [] {
        if item.action == #selector(AppDelegate.openFromMenu) { item.title = tr("Open Console") }
        if item.action == #selector(AppDelegate.openPanelFromMenu) { item.title = tr("Open Menu Panel") }
        if item.action == #selector(NSApplication.hide(_:)) { item.title = tr("Hide Thermo") }
        if item.action == #selector(NSApplication.terminate(_:)) { item.title = tr("Quit Thermo") }
    }
    if main.items.isEmpty { main.addItem(NSMenuItem()) }
    let item = NSMenuItem(title: tr("Edit"), action: nil, keyEquivalent: "")
    item.identifier = NSUserInterfaceItemIdentifier("thermo.edit")
    let menu = NSMenu(title: tr("Edit"))
    menu.addItem(withTitle: tr("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
    let redo = menu.addItem(withTitle: tr("Redo"), action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    menu.addItem(.separator())
    menu.addItem(withTitle: tr("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    menu.addItem(withTitle: tr("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    menu.addItem(withTitle: tr("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    menu.addItem(withTitle: tr("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    item.submenu = menu
    main.addItem(item)
    let viewItem = NSMenuItem(title: tr("View"), action: nil, keyEquivalent: "")
    viewItem.identifier = NSUserInterfaceItemIdentifier("thermo.view")
    let viewMenu = NSMenu(title: tr("View"))
    let pages: [(String, String, MainPage)] = [
        (tr("Overview"), "1", .overview), (tr("Sensors"), "2", .sensors), (tr("Fans"), "3", .fans),
        (tr("Browser pages"), "4", .browser("Google Chrome")), (tr("Disk Cleanup"), "5", .disk(.home)),
        (tr("AI Agent Diagnostics"), "6", .agents(.home)),
        (tr("Software"), "7", .apps(.installed)), (tr("Memory usage"), "8", .memory),
        (tr("CPU usage"), "9", .compute(false)), (tr("GPU usage"), "0", .compute(true)),
        (tr("Space Lens"), "", .space(.browse)), (tr("Claude tools"), "", .claude(.accounts)),
        (tr("Settings"), ",", .settings),
    ]
    for (title, key, page) in pages {
        let item = viewMenu.addItem(withTitle: title, action: #selector(PageMenuTarget.open(_:)), keyEquivalent: key)
        item.target = PageMenuTarget.shared
        item.representedObject = page
    }
    viewItem.submenu = viewMenu
    main.addItem(viewItem)
    let windowItem = NSMenuItem(title: tr("Window"), action: nil, keyEquivalent: "")
    windowItem.identifier = NSUserInterfaceItemIdentifier("thermo.window")
    let windowMenu = NSMenu(title: tr("Window"))
    windowMenu.addItem(withTitle: tr("Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    windowMenu.addItem(withTitle: tr("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    windowMenu.addItem(withTitle: tr("Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    windowItem.submenu = windowMenu
    main.addItem(windowItem)
    NSApp.windowsMenu = windowMenu
}

L10n.apply(preference: UserDefaults.standard.string(forKey: L10n.defaultsKey))
// Freeze launch metadata before an updater can replace the bundle on disk.
_ = AppInfo.buildMetadata
MainActor.assumeIsolated { _ = AppInstallationMonitor.shared }
let app = NSApplication.shared
// `--dump-status-menu`: print the menu bar item's menu (titles, separators, submenus) and quit,
// so its grouping and wording can be reviewed without opening it on screen.
if CommandLine.arguments.contains("--dump-status-menu") {
    MainActor.assumeIsolated {
        func dump(_ menu: NSMenu, _ depth: Int) {
            for item in menu.items {
                print(String(repeating: "    ", count: depth) + (item.isSeparatorItem ? "────" : item.title))
                if let sub = item.submenu { dump(sub, depth + 1) }
            }
        }
        dump(StatusMenu.shared.make(battery: true), 0)
    }
    exit(0)
}
// `--show-status-menu` / `--show-panel`: put the menu bar item's menu, or the panel in a plain window,
// on screen for a few seconds and quit, so they can be checked visually while another Thermo runs.
if CommandLine.arguments.contains("--show-status-menu") || CommandLine.arguments.contains("--show-panel") {
    app.setActivationPolicy(.accessory)
    MainActor.assumeIsolated {
        Settings.register()
        let center = NSScreen.main.map { NSPoint(x: $0.frame.midX - 160, y: $0.frame.midY + 240) } ?? .zero
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            NSApp.activate(ignoringOtherApps: true)
            if CommandLine.arguments.contains("--show-status-menu") {
                let menu = StatusMenu.shared.make(battery: true)
                let menuSeconds: TimeInterval = {
                    let args = CommandLine.arguments
                    guard let i = args.firstIndex(of: "--menu-seconds"), i + 1 < args.count,
                          let value = Double(args[i + 1]), value.isFinite, (2...120).contains(value) else { return 6 }
                    return value
                }()
                let close = Timer(timeInterval: menuSeconds, repeats: false) { _ in menu.cancelTracking() }
                RunLoop.main.add(close, forMode: .common)
                print("shown"); fflush(stdout)
                // Where the menu bar item would drop it: just under the menu bar.
                let top = NSScreen.main.map { NSPoint(x: $0.frame.maxX - 560, y: $0.visibleFrame.maxY) } ?? center
                menu.popUp(positioning: nil, at: top, in: nil)
                exit(0)
            }
            let monitor = AppModels.shared.monitor
            SystemPulse.shared.start()
            PanelModel.shared.setActive(true)
            monitor.popoverOpen = true
            let w = NSWindow(contentRect: NSRect(x: center.x, y: center.y - 560, width: 360, height: 600),
                             styleMask: [.titled], backing: .buffered, defer: false)
            w.title = "Thermo panel check"
            w.contentView = NSHostingView(rootView: PopoverView(monitor: monitor))
            w.makeKeyAndOrderFront(nil)
            print("shown"); fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) { exit(0) }
        }
    }
    app.run()
}
// Snapshot/render jobs do not present interactive windows or create Dock items.
if !CommandLine.arguments.contains("--offscreen"), !CommandLine.arguments.contains("--render-preview"), !CommandLine.arguments.contains("--verify-lifecycle") {
    do {
        guard try MainActor.assumeIsolated({ try SingleInstance.claim() }) else { exit(0) }
    } catch {
        fputs("Thermo cannot acquire its instance lock: \(error)\n", stderr)
        exit(1)
    }
}
if CommandLine.arguments.contains("--verify-lifecycle") {
    do {
        let options = try MainActor.assumeIsolated { try WindowLifecycleCheck.Options(arguments: CommandLine.arguments) }
        app.setActivationPolicy(.accessory)
        let lifecycleDelegate = MainActor.assumeIsolated { MainOnlyDelegate() }
        app.delegate = lifecycleDelegate
        DispatchQueue.main.async {
            Task { @MainActor in
                do {
                    let report = try await WindowLifecycleCheck.run(options)
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                    try encoder.encode(report).write(to: URL(fileURLWithPath: options.output), options: .atomic)
                    exit(report.functionalChecksPassed ? 0 : 2)
                } catch { fputs("Lifecycle verification failed: \(error)\n", stderr); exit(1) }
            }
        }
        withExtendedLifetime(lifecycleDelegate) { app.run() }
    } catch { fputs("Lifecycle verification failed: \(error)\n", stderr); exit(1) }
}
if let i = CommandLine.arguments.firstIndex(of: "--render-preview"), i + 1 < CommandLine.arguments.count {
    app.setActivationPolicy(.prohibited)
    MainActor.assumeIsolated { renderPreviews(to: CommandLine.arguments[i + 1]) }
    app.run()
}
/// `Thermo --main [--page PAGE]` (and the older `--disk [PAGE]`, `--agents [AREA]`, `--chrome-pages`):
/// `--inspect-memory NAME` expands that program for read-only layout review.
/// just the main window, no menu bar item; quits when closed. With `--offscreen --snapshot PATH` it
/// draws the window into a PNG once the page has its data, and quits (verification).
/// `--fixture BEFORE.json AFTER.json` shows two saved browser samples instead of measuring.
/// `--ui-review` keeps a visible window while suppressing automatic helper/policy restoration.
@MainActor func openMainOnly(_ args: [String]) {
    Settings.register()
    if !Monitor.suppressesAutomaticControl(arguments: args) {
        CleanScreenShortcutModel.enableLive()
        BatteryCareModel.shared.restoreSavedPreference()
    }
    installStandardMenus()
    ModuleCenter.shared.start()
    let models = AppModels.shared
    func value(after flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    var page = value(after: "--page").flatMap(MainPage.init(argument:)) ?? .overview
    if value(after: "--page") == "apps:feeds" { models.softwareUpdates.channel = "native" }
    if args.contains("--disk") {
        page = .disk(value(after: "--page").flatMap(DiskPage.init(argument:)) ?? .home)
        if args.contains("--all") { models.disk.scope = .all }
        if !args.contains("--no-scan") {
            let category: CleanCategory?
            if case let .disk(.category(selected)) = page { category = selected } else { category = nil }
            models.disk.loadSaved(category: category, scanIfMissing: true)
        }
    }
    if args.contains("--agents") {
        page = .agents(value(after: "--agents").flatMap(Area.init(rawValue:)).map { .area($0) } ?? .home)
        models.agents.scan()
    }
    if args.contains("--chrome-pages") {
        let name = value(after: "--app") ?? "Google Chrome"
        let hog = MachinePulse.sample().hogs.first { $0.name == name }
        let model = models.browser(name, memoryKB: hog?.memoryKB, gpuKB: hog?.parts?.first { $0.role == "GPU" }?.memoryKB)
        if let i = args.firstIndex(of: "--fixture"), i + 2 < args.count {
            model.loadFixture(before: args[i + 1], after: args[i + 2])
        }
        page = .browser(name)
    }
    if page == .checkup, let i = args.firstIndex(of: "--fixture"), i + 1 < args.count {
        CheckupModel.shared.loadFixture(answer: args[i + 1])
    }
    if page == .memory, let i = args.firstIndex(of: "--fixture"), i + 1 < args.count {
        MemoryReliefAdvice.shared.loadFixture(answer: args[i + 1])
    }
    MainWindow.show(page)
    // `--height N`: a taller window, so a snapshot can show what sits below the fold.
    if let h = value(after: "--height").flatMap(Double.init), let w = MainWindow.window {
        var frame = w.frame; frame.size.height = h; w.setFrame(frame, display: true)
    }
    guard let path = value(after: "--snapshot") else { return }
    let started = Date()
    MainWindow.snapshot(to: path) {
        // Give each page what it needs to be worth a picture, but never wait more than 90 s.
        if Date().timeIntervalSince(started) > 90 { return true }
        switch page {
        case .disk: return !models.disk.loadingSaved && (args.contains("--no-scan") ? !models.disk.scanning : models.disk.report != nil && !models.disk.scanning)
        case .agents: return models.agents.report != nil && !models.agents.scanning
        case .claude(.accounts): return ClaudeAccountsModel.shared.loaded
        case .claude: return models.claudeCleanup.loaded && !models.claudeCleanup.busy
        case .history: return HistoryModel.shared.loaded
        case let .browser(app): return TabWorkspaceModel.loadedApps.contains(app)
        case .apps(.installed): return !models.apps.loading && !models.apps.apps.isEmpty
        case .apps(.leftovers): return models.apps.orphans != nil
        case .apps(.startup): return models.startup.report != nil && !models.startup.busy
        case .apps(.updates): return models.softwareUpdates.channel == "native"
            ? models.nativeUpdates.loaded && !models.nativeUpdates.loading
            : models.softwareUpdates.report != nil && !models.softwareUpdates.busy
        case .apps(.store): return models.appStore.loaded
        case .plugins: return models.plugins.loaded && !models.plugins.checkingUpdates
        case let .module(id, _):
            // Worth a picture once the module's process is up, or once it is known to be off.
            guard ModuleCenter.shared.loaded else { return false }
            let status = ModuleCenter.shared.manager.status(id)
            return status?.enabled != true || (status?.phase == .running && Date().timeIntervalSince(started) > 3)
        case .compute: return ComputeModel.shared.current?.cpu != nil && Date().timeIntervalSince(started) > 4
        case .connections: return ConnectionsModel.shared.bluetooth != nil || ConnectionsModel.shared.bluetoothFailed
        case .memory: return MemoryModel.shared.breakdown != nil && Date().timeIntervalSince(started) > 4
        case .space(.duplicates): return true
        case .space: return SpaceLensModel.shared.tree != nil && !SpaceLensModel.shared.scanning
        case .checkup: return Date().timeIntervalSince(started) > 2
        case .overview: return models.monitor.snapshot != nil && SystemPulse.shared.sampled && PulseRecorder.shared.diagnosis != nil && Date().timeIntervalSince(started) > 4
        default: return models.monitor.snapshot != nil
        }
    }
}

if ["--main", "--disk", "--agents", "--chrome-pages"].contains(where: CommandLine.arguments.contains) {
    let mainOnlyDelegate = MainActor.assumeIsolated { MainOnlyDelegate() }
    app.delegate = mainOnlyDelegate
    // `--offscreen`: no Dock icon, no window on the user's screen.
    app.setActivationPolicy(CommandLine.arguments.contains("--offscreen") ? .accessory : .regular)
    DispatchQueue.main.async { MainActor.assumeIsolated { openMainOnly(CommandLine.arguments) } }
    // Only the main window closing ends the app (not sheets, menus or alerts).
    let closeObserver = MainActor.assumeIsolated { MainOnlyDelegate.observeMainWindowClosing() }
    withExtendedLifetime((mainOnlyDelegate, closeObserver)) { app.run() }
}
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
