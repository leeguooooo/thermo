import AppKit
import SwiftUI
import AgentDoctor
import ThermoKit
import ThermoL10n

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var monitor: Monitor!
    private let updates = Updates()
    private let disk = DiskModel()
    private var lastTitle: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.register()
        monitor = Monitor()

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
        popover.contentViewController = NSHostingController(rootView: PopoverView(monitor: monitor, updates: updates, disk: disk))

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
            L10n.apply(preference: UserDefaults.standard.string(forKey: L10n.defaultsKey))
            self?.monitor.reschedule()
            self?.applyDockPreference()
            if let s = self?.monitor.latest { self?.updateTitle(s) }
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            if let s = self?.monitor.latest { self?.updateTitle(s) }
            self?.applyDockPreference()
        }
    }

    /// Clicking the Dock icon (or opening Thermo.app again) shows the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
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
        appMenu.addItem(withTitle: tr("Open Thermo"), action: #selector(openFromMenu), keyEquivalent: "o").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("Hide Thermo"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: tr("Quit Thermo"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }

    @objc private func openFromMenu() { showPanel() }

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
        let fanRPM = s.fans.map(\.rpm).max()

        let text: String
        switch metric {
        case .cpu: text = t(s.cpu ?? s.hottest)
        case .hottest: text = t(s.hottest)
        case .fan: text = fanRPM.map { "\(Int($0)) rpm" } ?? t(s.hottest)
        case .cpuAndFan: text = t(s.cpu ?? s.hottest) + (fanRPM.map { " · " + rpm($0) } ?? "")
        case .power: text = s.systemPower.map { String(format: "%.0f W", $0) } ?? t(s.hottest)
        case .iconOnly: text = ""
        }
        // Redrawing the status item costs ~2 ms; skip it when nothing visible changed.
        let title = text.isEmpty ? "" : " " + text
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

/// Debug aid: `Thermo --render-preview DIR` writes each popover tab as a PNG and exits.
@MainActor func renderPreviews(to dir: String) {
    Settings.register()
    renderingPreview = true
    let monitor = Monitor()
    let updates = Updates()
    let disk = DiskModel()
    disk.scan()
    // ImageRenderer never fires onAppear; start the "why is it slow" sampler up front.
    SystemPulse.shared.start()
    monitor.popoverOpen = true
    let agents = AgentScanner()
    let started = Date()
    agents.scan()
    // Sensors are ready after a few seconds; the agent and disk scans can take longer (up to 90 s).
    func render() {
        if agents.scanning || disk.scanning || disk.report == nil, Date().timeIntervalSince(started) < 90 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: render)
            return
        }
        for tab in Tab.allCases {
            let view = PopoverView(monitor: monitor, updates: updates, disk: disk, tab: tab, agents: agents).background(Color(nsColor: .windowBackgroundColor))
            let r = ImageRenderer(content: view)
            r.scale = 2
            guard let img = r.cgImage else { continue }
            let rep = NSBitmapImageRep(cgImage: img)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(tab.rawValue.lowercased()).png"))
        }
        // The disk cleanup confirmation for the default (safe) selection.
        let sheet = ImageRenderer(content: DiskView.confirmPreview(disk).background(Color(nsColor: .windowBackgroundColor)))
        sheet.scale = 2
        if let img = sheet.cgImage {
            try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("disk-confirm.png"))
        }
        exit(0)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: render)
}

L10n.apply(preference: UserDefaults.standard.string(forKey: L10n.defaultsKey))
let app = NSApplication.shared
if let i = CommandLine.arguments.firstIndex(of: "--render-preview"), i + 1 < CommandLine.arguments.count {
    app.setActivationPolicy(.prohibited)
    MainActor.assumeIsolated { renderPreviews(to: CommandLine.arguments[i + 1]) }
    app.run()
}
/// `Thermo --disk`: just the Disk Cleanup window — no menu bar item, no fan helper; quits when closed.
if CommandLine.arguments.contains("--disk") {
    app.setActivationPolicy(.regular)
    let disk = MainActor.assumeIsolated { DiskModel() }
    // After launch finishes, or the app cannot come to the front.
    DispatchQueue.main.async { MainActor.assumeIsolated { DiskWindow.show(disk) } }
    NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in exit(0) }
    app.run()
}
/// `Thermo --agents`: just the AI agent diagnostics window — no menu bar item, no fan helper; quits when closed.
if CommandLine.arguments.contains("--agents") {
    // `--offscreen` (verification screenshots): no Dock icon, no window on the user's screen.
    app.setActivationPolicy(CommandLine.arguments.contains("--offscreen") ? .accessory : .regular)
    MainActor.assumeIsolated {
        let scanner = AgentScanner()
        scanner.scan()
        // `--agents mcp` opens one area directly.
        let args = CommandLine.arguments
        let area = args.firstIndex(of: "--agents").flatMap { $0 + 1 < args.count ? Area(rawValue: args[$0 + 1]) : nil }
        AgentsWindow.show(scanner, entry: area.map { .area($0) } ?? .home)
        // `--snapshot PATH` (with --offscreen): once the check is done, draw the window into a PNG and quit.
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            AgentsWindow.snapshotWhenReady(scanner, to: args[i + 1])
        }
    }
    // Quit when the diagnostics window closes; not when a menu or sheet window inside it does.
    NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { n in
        MainActor.assumeIsolated { if let w = n.object as? NSWindow, w === AgentsWindow.window { exit(0) } }
    }
    app.run()
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
