import AppKit
import ThermoKit
import ThermoL10n

/// The tools in the menu bar panel that open a panel of their own.
enum ToolSheet: String, Identifiable {
    case keepAwake, cleanScreen, lowLatency, batteryCare
    var id: String { rawValue }
}

/// The menu bar item's menu: every place in the window and every tool, one click away, grouped
/// the way the window's sidebar is (the Mac's state, cleanup, AI agents), then the tools, then the app.
/// Native, so it reads like any other menu on the Mac: a symbol on each row, shortcuts on the right.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    static let shared = StatusMenu()

    func make(battery: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item(tr("Open Thermo"), "macwindow", key: "o") { MainWindow.show() })
        menu.addItem(item(tr("Search apps and files"), "magnifyingglass") { LocalSearchPanel.shared.show() })
        menu.addItem(item(tr("Capture screen…") + "  ⌥⌘3", "viewfinder") { CaptureWorkspace.shared.capture() })
        menu.addItem(item(tr("Pin clipboard") + "  ⌥⌘4", "pin") { CaptureWorkspace.shared.pinClipboard() })
        menu.addItem(item(tr("Open image…"), "photo") { CaptureWorkspace.shared.importImage() })
        menu.addItem(item(tr("Scrolling capture…"), "arrow.down.right.and.arrow.up.left") { CaptureWorkspace.shared.captureScrolling() })
        menu.addItem(item(tr("Record screen…"), "record.circle") { CaptureWorkspace.shared.recordScreen() })
        menu.addItem(item(tr("Recording drafts…"), "film.stack") { CaptureWorkspace.shared.recordScreen(draftsOnly:true) })
        menu.addItem(item(tr("Settings…"), "gearshape", key: ",") { MainWindow.show(.settings) })
        menu.addItem(.separator())

        menu.addItem(page(tr("Overview"), "gauge.with.dots.needle.67percent", .overview))
        menu.addItem(page(tr("Sensors"), "thermometer.medium", .sensors))
        menu.addItem(page(tr("Fans"), "fan", .fans))
        menu.addItem(page(tr("Connections"), "wifi", .connections))
        menu.addItem(page(tr("Memory usage"), "memorychip", .memory))
        menu.addItem(.separator())

        menu.addItem(page(tr("Smart Scan"), "sparkles", .disk(.home)))
        menu.addItem(page(tr("Space Lens"), "square.grid.3x3.topleft.filled", .space(.browse)))
        menu.addItem(page(tr("Software"), "square.grid.2x2", .apps(.installed)))
        menu.addItem(page(tr("Tab organizer"), "rectangle.stack", .browser("Google Chrome")))
        menu.addItem(.separator())

        menu.addItem(page(tr("Claude cleanup"), "arrow.counterclockwise.circle", .claudeCleanup))
        menu.addItem(page(tr("Smart Check"), "stethoscope", .agents(.home)))
        menu.addItem(.separator())

        menu.addItem(keepAwake())
        menu.addItem(item(tr("Clean Screen"), "sparkles.tv") { MainWindow.show(tool: .cleanScreen) })
        menu.addItem(item(tr("Network low latency"), "network") { MainWindow.show(tool: .lowLatency) })
        if battery {
            menu.addItem(item(tr("Battery charging protection"), "battery.75") { MainWindow.show(tool: .batteryCare) })
        }
        menu.addItem(.separator())

        menu.addItem(page(tr("History"), "clock.arrow.circlepath", .history))
        let check = item(tr("Check for Updates…"), "arrow.triangle.2.circlepath") { AppModels.shared.updates.checkForUpdates() }
        check.isEnabled = AppModels.shared.updates.canCheck
        menu.addItem(check)
        menu.addItem(item(tr("About Thermo"), "info.circle") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        })
        menu.addItem(.separator())
        menu.addItem(item(tr("Quit Thermo"), "power", key: "q") { NSApp.terminate(nil) })
        return menu
    }

    /// Keep awake: the common lengths right here, everything else in its panel.
    private func keepAwake() -> NSMenuItem {
        let model = IdleAwakeModel.shared
        let parent = NSMenuItem(title: tr("Keep awake"), action: nil, keyEquivalent: "")
        parent.image = symbol("cup.and.saucer")
        if model.state.phase == .active { parent.state = .on }
        let sub = NSMenu()
        sub.autoenablesItems = false
        if model.canStop {
            sub.addItem(item(tr("Stop keeping awake"), "stop.circle") { model.stop() })
            sub.addItem(.separator())
        }
        for (title, seconds) in [(tr("30 minutes"), 1800.0), (tr("1 hour"), 3600.0), (tr("2 hours"), 7200.0)] {
            let entry = item(title, nil) { model.start(mode: .both, seconds: seconds) }
            entry.isEnabled = model.canStart
            sub.addItem(entry)
        }
        let forever = item(tr("Until I turn it off"), nil) { model.start(mode: .both, seconds: nil) }
        forever.isEnabled = model.canStart
        sub.addItem(forever)
        sub.addItem(.separator())
        sub.addItem(item(tr("Options…"), "slider.horizontal.3") { MainWindow.show(tool: .keepAwake) })
        parent.submenu = sub
        return parent
    }

    private func page(_ title: String, _ symbolName: String, _ target: MainPage) -> NSMenuItem {
        item(title, symbolName) { MainWindow.show(target) }
    }

    private func item(_ title: String, _ symbolName: String?, key: String = "", run: @escaping @MainActor () -> Void) -> NSMenuItem {
        let entry = ActionItem(title: title, run: run)
        entry.keyEquivalent = key
        entry.image = symbolName.flatMap(symbol)
        return entry
    }

    private func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }
}

/// A menu item that runs a closure.
private final class ActionItem: NSMenuItem {
    private let run: @MainActor () -> Void
    init(title: String, run: @escaping @MainActor () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }
    @objc private func fire() { MainActor.assumeIsolated { run() } }
}
