import AppKit
import ThermoKit
import ThermoL10n

/// The tools in the menu bar panel that open a panel of their own.
enum ToolSheet: String, Identifiable {
    case keepAwake, cleanScreen, lowLatency, batteryCare, focus
    var id: String { rawValue }
}

/// The menu bar item's menu: every place in the window and every tool, one click away, grouped
/// the way the window's sidebar is (the Mac's state, cleanup, AI agents), then the tools, then the app.
/// Native, so it reads like any other menu on the Mac: a symbol on each row, shortcuts on the right.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    static let shared = StatusMenu()

    func make(battery: Bool) -> NSMenu {
        let captureShortcutSuffix = CaptureWorkspace.shared.shortcutSuffix(for: .screenshot)
        let pinShortcutSuffix = CaptureWorkspace.shared.shortcutSuffix(for: .pinClipboard)
        
        let configuredEntries = CaptureWorkspace.shared.shortcuts.settings.entries
            .filter { $0.appearsInMenu }
            .map { entry -> String in
                let label = CaptureWorkspace.shared.shortcuts.label(for: entry)
                return (entry.title.isEmpty ? tr(entry.action.title) : entry.title) + (label.isEmpty ? "" : "  " + label)
            }
        
        let menuBarManager = MenuBarManager.shared
        let menuBarQuickControlsAppear = menuBarManager.enabled || menuBarManager.state != .visible
        
        let context = StatusMenuLayout.RuntimeContext(
            hasBattery: battery,
            keepAwakeActive: IdleAwakeModel.shared.state.phase == .active,
            focusTimerActive: FocusTimerModel.shared.phase.isActive,
            configuredCaptureEntriesAppear: !configuredEntries.isEmpty,
            menuBarQuickControlsAppear: menuBarQuickControlsAppear,
            updatesCanCheck: AppModels.shared.updates.canCheck,
            moreToolsActiveStates: StatusMenuLayout.MoreToolsActiveStates(
                cleanScreenActive: CleanScreenModel.shared.active,
                lowLatencyActive: AWDLModel.shared.state?.phase == .active,
                batteryProtectionActive: battery && (BatteryCareModel.shared.state?.ownedByCaller == true)
            )
        )
        
        let layout = StatusMenuLayout.make(
            context: context,
            captureShortcutSuffix: captureShortcutSuffix,
            pinShortcutSuffix: pinShortcutSuffix,
            configuredCaptureEntries: configuredEntries
        )
        
        return materialize(layout: layout)
    }
    
    private func materialize(layout: StatusMenuLayout) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        
        for productItem in layout.productItems {
            switch productItem {
            case .openThermo:
                menu.addItem(item(tr("Open Thermo"), "macwindow", key: "o") { MainWindow.show() })
                
            case .searchAppsAndFiles:
                menu.addItem(item(tr("Search apps and files"), "magnifyingglass") { LocalSearchPanel.shared.show() })
                
            case .menuGroup(let group):
                menu.addItem(materializeGroup(group))
                
            case .directStatusItem(let status):
                if status.title == "Keep awake" {
                    menu.addItem(keepAwake())
                } else if status.title == "Focus timer" {
                    let focus = NSMenuItem(title: tr("Focus timer"), action: nil, keyEquivalent: "")
                    focus.image = symbol("timer")
                    if status.isActive { focus.state = .on }
                    focus.submenu = focusMenu()
                    menu.addItem(focus)
                }
                
            case .manageMenuBar:
                for control in MenuBarQuickControls.items(model: .shared) { menu.addItem(control) }
                menu.addItem(item(tr("Manage menu bar…"), "menubar.rectangle") { MenuBarManagerPanel.shared.show() })
                
            case .history:
                menu.addItem(page(tr("History"), "clock.arrow.circlepath", .history))
                
            case .settings:
                menu.addItem(item(tr("Settings…"), "gearshape", key: ",") { MainWindow.show(.settings) })
            }
        }
        
        menu.addItem(.separator())
        
        let check = item(tr("Check for Updates…"), "arrow.triangle.2.circlepath") { AppModels.shared.updates.checkForUpdates() }
        check.isEnabled = layout.retainedExtras.footer.checkForUpdatesEnabled
        menu.addItem(check)
        menu.addItem(item(tr("About Thermo"), "info.circle") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        })
        menu.addItem(.separator())
        menu.addItem(item(tr("Quit Thermo"), "power", key: "q") { NSApp.terminate(nil) })
        
        return menu
    }
    
    private func materializeGroup(_ group: StatusMenuLayout.MenuGroup) -> NSMenuItem {
        let parent = NSMenuItem(title: tr(group.title), action: nil, keyEquivalent: "")
        if group.hasActiveHint {
            parent.state = .on
        }
        
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        
        for leaf in group.leaves {
            switch leaf {
            case .captureScreen(let suffix):
                submenu.addItem(item(tr("Capture screen…") + suffix, "viewfinder") { CaptureWorkspace.shared.capture() })
            case .scrollingCapture:
                submenu.addItem(item(tr("Scrolling capture…"), "arrow.down.right.and.arrow.up.left") { CaptureWorkspace.shared.captureScrolling() })
            case .recordScreen:
                submenu.addItem(item(tr("Record screen…"), "record.circle") { CaptureWorkspace.shared.recordScreen() })
            case .recordingDrafts:
                submenu.addItem(item(tr("Recording drafts…"), "film.stack") { CaptureWorkspace.shared.recordScreen(draftsOnly: true) })
            case .openImage:
                submenu.addItem(item(tr("Open image…"), "photo") { CaptureWorkspace.shared.importImage() })
            case .configuredCaptureActions(let entries):
                let configured = NSMenu()
                configured.autoenablesItems = false
                for (index, _) in entries.enumerated() {
                    let entry = CaptureWorkspace.shared.shortcuts.settings.entries.filter { $0.appearsInMenu }[index]
                    let label = CaptureWorkspace.shared.shortcuts.label(for: entry)
                    configured.addItem(item((entry.title.isEmpty ? tr(entry.action.title) : entry.title) + (label.isEmpty ? "" : "  " + label), nil) {
                        let workspace = CaptureWorkspace.shared
                        workspace.shortcuts.run(entry)
                        if workspace.shortcuts.issue != nil { workspace.showActionSettings() }
                    })
                }
                let configItem = NSMenuItem(title: tr("Configured capture actions"), action: nil, keyEquivalent: "")
                configItem.submenu = configured
                submenu.addItem(configItem)
            case .captureSavingSettings:
                submenu.addItem(item(tr("Capture saving and after-actions"), "square.and.arrow.down") { CaptureWorkspace.shared.showSavingSettings() })
            case .captureShortcutsSettings:
                submenu.addItem(item(tr("Capture shortcuts and actions"), "keyboard") { CaptureWorkspace.shared.showActionSettings() })
            case .pinClipboard(let suffix):
                submenu.addItem(item(tr("Pin clipboard") + suffix, "pin") { CaptureWorkspace.shared.pinClipboard() })
            case .pinClipboardAsText:
                submenu.addItem(item(tr("Pin clipboard as text"), "text.quote") { CaptureWorkspace.shared.pinClipboard(asText: true) })
            case .pinClipboardAsLaTeX:
                submenu.addItem(item(tr("Pin clipboard as LaTeX"), "function") { CaptureWorkspace.shared.pinClipboard(asLaTeX: true) })
            case .pinGroupsAndHistory:
                submenu.addItem(item(tr("Pin groups and history"), "square.stack") { CaptureWorkspace.shared.showPinLibrary() })
            case .restoreLastClosedPin:
                submenu.addItem(item(tr("Restore last closed pin"), "arrow.uturn.backward") { CaptureWorkspace.shared.restoreLastPin() })
            case .restorePinMouseInteraction:
                submenu.addItem(item(tr("Restore pin mouse interaction"), "cursorarrow") { CaptureWorkspace.shared.pinSession.restoreMouseInteraction() })
            case .overview:
                submenu.addItem(page(tr("Overview"), "gauge.with.dots.needle.67percent", .overview))
            case .aiCheckup:
                submenu.addItem(page(tr("AI Check-up"), "waveform.path.ecg", .checkup))
            case .sensors:
                submenu.addItem(page(tr("Sensors"), "thermometer.medium", .sensors))
            case .fans:
                submenu.addItem(page(tr("Fans"), "fan", .fans))
            case .connections:
                submenu.addItem(page(tr("Connections"), "wifi", .connections))
            case .cpuUsage:
                submenu.addItem(page(tr("CPU usage"), "cpu", .compute(false)))
            case .gpuUsage:
                submenu.addItem(page(tr("GPU usage"), "square.stack.3d.up", .compute(true)))
            case .memoryUsage:
                submenu.addItem(page(tr("Memory usage"), "memorychip", .memory))
            case .tabOrganizer:
                submenu.addItem(page(tr("Tab organizer"), "rectangle.stack", .browser("Google Chrome")))
            case .smartScan:
                submenu.addItem(page(tr("Smart Scan"), "sparkles", .disk(.home)))
            case .spaceLens:
                submenu.addItem(page(tr("Space Lens"), "square.grid.3x3.topleft.filled", .space(.browse)))
            case .software:
                submenu.addItem(page(tr("Software"), "square.grid.2x2", .apps(.installed)))
            case .claudeTools:
                submenu.addItem(page(tr("Claude tools"), "person.2", .claude(.accounts)))
            case .smartCheck:
                submenu.addItem(page(tr("Smart Check"), "stethoscope", .agents(.home)))
            case .cleanScreen:
                submenu.addItem(item(tr("Clean Screen"), "sparkles.tv") { MainWindow.show(tool: .cleanScreen) })
            case .networkLowLatency:
                submenu.addItem(item(tr("Network low latency"), "network") { MainWindow.show(tool: .lowLatency) })
            case .batteryProtection:
                submenu.addItem(item(tr("Battery charging protection"), "battery.75") { MainWindow.show(tool: .batteryCare) })
            }
        }
        
        parent.submenu = submenu
        return parent
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

    /// 主菜单的子菜单和计时状态项的菜单共用，按当前阶段列出可做的操作。
    func focusMenu() -> NSMenu {
        let model = FocusTimerModel.shared
        let sub = NSMenu()
        sub.autoenablesItems = false
        for action in FocusAction.available(in: model.phase) {
            sub.addItem(item(action.title, nil) { action.run(model) })
        }
        sub.addItem(.separator())
        sub.addItem(item(tr("Focus timer options…"), "slider.horizontal.3") { MainWindow.show(tool: .focus) })
        return sub
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
