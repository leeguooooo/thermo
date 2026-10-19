import AppKit
import UserNotifications
import SwiftUI
import AgentDoctor
import CleanKit
import ThermoKit
import ThermoL10n

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var monitor: Monitor { AppModels.shared.monitor }
    private var lastTitle: String?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { AppExitGuard.reply() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.register()
        AppControlHost.shared.start()
        CleanScreenShortcutModel.enableLive()
        BatteryCareModel.shared.restoreSavedPreference()
        _ = AppModels.shared.updates  // Sparkle starts checking with the app
        // Slowdown history and alerts, in the background whether or not the panel is open.
        PulseRecorder.shared.start()
        TabAutomation.shared.start()
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate = self }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: "Thermo")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.action = #selector(toggle)
            button.target = self
        }

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PopoverView(monitor: monitor))
        IdleAwakeModel.shared.onStateChange = { [weak self] in
            guard let self, let snapshot = self.monitor.snapshot else { return }
            self.updateTitle(snapshot)
        }
        // The panel's curves keep a slow history while it is closed.
        PanelModel.shared.setActive(false)

        applyDockPreference()
        installMainMenu()
        // macOS hides status items that do not fit next to the notch, without telling anyone.
        // Check once the item has been laid out; if nobody can see it, open the panel ourselves.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.statusItemHidden() else { return }
            self.monitor.iconHidden = true
            self.showPanel()
        }

        monitor.onUpdate = { [weak self] s in self?.updateTitle(s) }
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
                if let s = self?.monitor.latest { self?.updateTitle(s) }
            }
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Settings.normalize()
            MainActor.assumeIsolated {
                if let s = self?.monitor.latest { self?.updateTitle(s) }
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
        appMenu.addItem(withTitle: tr("Save and close background tabs"), action: #selector(archiveTabsFromMenu), keyEquivalent: "s").target = self
        appMenu.items.last?.keyEquivalentModifierMask = [.command, .shift]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("Hide Thermo"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: tr("Quit Thermo"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = main
        installStandardMenus()
    }

    @objc fileprivate func archiveTabsFromMenu() { TabQuickAction.request() }

    @objc fileprivate func openFromMenu() { MainWindow.show() }

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
        guard !popover.isShown else { return }
        monitor.popoverOpen = true
        if let button = statusItem.button, !statusItemHidden() {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        } else {
            let anchor = panelAnchor()
            popover.show(relativeTo: anchor.contentView!.bounds, of: anchor.contentView!, preferredEdge: .minY)
        }
        popover.contentViewController?.view.window?.makeKey()
    }

    private var anchorWindow: NSWindow?

    /// An invisible 1×1 window just below the menu bar, centred, for the popover to hang from.
    private func panelAnchor() -> NSWindow {
        let screen = NSScreen.main ?? NSScreen.screens[0]
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
        // Fan policies live in the helper and intentionally survive the app quitting.
    }

    @objc private func toggle() {
        if popover.isShown { popover.performClose(nil) } else { showPanel() }
    }

    func popoverDidClose(_ notification: Notification) { monitor.popoverOpen = false }

    private func updateTitle(_ s: Snapshot) {
        guard let button = statusItem.button else { return }
        let d = UserDefaults.standard
        let metric = TitleMetric(rawValue: d.string(forKey: Settings.titleMetric) ?? "") ?? .cpu
        let f = d.bool(forKey: Settings.fahrenheit)
        func t(_ c: Double?) -> String {
            guard let c else { return "—" }
            return f ? String(format: "%.0f°", c * 9 / 5 + 32) : String(format: "%.0f°", c)
        }
        func rpm(_ r: Double) -> String { r >= 1000 ? String(format: "%.1fk", r / 1000) : String(Int(r)) }
        let fanRPM = s.fans.compactMap(\.rpm).max()

        let text: String
        switch metric {
        case .cpu: text = t(s.cpu ?? s.maximumKnownTemperature)
        case .hottest: text = t(s.maximumKnownTemperature)
        case .fan: text = FanControlPresentation.speedSummary(s.fans) ?? t(s.maximumKnownTemperature)
        case .cpuAndFan: text = t(s.cpu ?? s.maximumKnownTemperature) + (fanRPM.map { " · " + (s.fans.contains { $0.rpm == nil } ? "≥ " : "") + rpm($0) } ?? (s.fans.isEmpty ? "" : " · " + tr("unknown")))
        case .power: text = s.systemPower.map { String(format: "%.0f W", $0) } ?? t(s.maximumKnownTemperature)
        case .iconOnly: text = ""
        }
        // Redrawing the status item costs ~2 ms; skip it when nothing visible changed.
        let awake = IdleAwakeModel.shared.state
        let marker = awake.phase == .active ? "☕︎" : awake.phase == .ending ? "☕︎?" : awake.requested ? "☕︎⏸" : ""
        let combined = [text, marker].filter { !$0.isEmpty }.joined(separator: " ")
        let title = combined.isEmpty ? "" : " " + combined
        if title != lastTitle {
            lastTitle = title
            button.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            ])
        }
        let tip = String(format: "CPU %@ · GPU %@", t(s.cpu), t(s.gpu))
        if button.toolTip != tip { button.toolTip = tip }
    }
}

/// Debug aid: `Thermo --render-preview DIR` writes the menu bar panel as a PNG and exits.
/// (The main window's pages: `Thermo --main --offscreen --page PAGE --snapshot PATH`.)
@MainActor func renderPreviews(to dir: String) {
    Settings.register()
    renderingPreview = true
    let monitor = AppModels.shared.monitor
    // ImageRenderer never fires onAppear; start the "why is it slow" sampler up front.
    SystemPulse.shared.start()
    PanelModel.shared.setActive(true)
    monitor.popoverOpen = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
        let r = ImageRenderer(content: PopoverView(monitor: monitor).background(Color(nsColor: .windowBackgroundColor)))
        r.scale = 2
        if let img = r.cgImage {
            try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("panel.png"))
        }
        exit(0)
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
        (tr("AI Agent Diagnostics"), "6", .agents(.home)), (tr("Settings"), ",", .settings),
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
let app = NSApplication.shared
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
    MainWindow.show(page)
    guard let path = value(after: "--snapshot") else { return }
    let started = Date()
    MainWindow.snapshot(to: path) {
        // Give each page what it needs to be worth a picture, but never wait more than 90 s.
        if Date().timeIntervalSince(started) > 90 { return true }
        switch page {
        case .disk: return !models.disk.loadingSaved && (args.contains("--no-scan") ? !models.disk.scanning : models.disk.report != nil && !models.disk.scanning)
        case .agents: return models.agents.report != nil && !models.agents.scanning
        case .claudeCleanup, .privacyTools: return models.claudeCleanup.loaded && !models.claudeCleanup.busy
        case .history: return HistoryModel.shared.loaded
        case let .browser(app): return TabWorkspaceModel.loadedApps.contains(app)
        case .apps(.installed): return !models.apps.loading && !models.apps.apps.isEmpty
        case .apps(.leftovers): return models.apps.orphans != nil
        case .apps(.startup): return models.startup.report != nil && !models.startup.busy
        case .apps(.updates): return models.softwareUpdates.channel == "native"
            ? models.nativeUpdates.loaded && !models.nativeUpdates.loading
            : models.softwareUpdates.report != nil && !models.softwareUpdates.busy
        case .compute: return ComputeModel.shared.current?.cpu != nil && Date().timeIntervalSince(started) > 4
        case .memory: return MemoryModel.shared.breakdown != nil && Date().timeIntervalSince(started) > 4
        case .space(.duplicates): return true
        case .space: return SpaceLensModel.shared.tree != nil && !SpaceLensModel.shared.scanning
        case .overview: return models.monitor.snapshot != nil && SystemPulse.shared.sampled && Date().timeIntervalSince(started) > 4
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
