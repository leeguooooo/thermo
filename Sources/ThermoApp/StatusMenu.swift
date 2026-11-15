import NativeFeatureAPI
import ModuleKit
import ThermoUI
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
        let nativeEntries=BuiltinNativeFeatures.catalog.menuEntries.filter{$0.hasContent && ModuleCenter.shared.isOn($0.ref.module)}
        let retained=AppModels.shared.nativeFeatures.retainedMenuContent()
        
        let context = StatusMenuLayout.RuntimeContext(
            nativeMenusAppear:!nativeEntries.isEmpty,
            menuBarEnabled: MenuBarModule.enabled,
            performanceEnabled: PerformanceModule.enabled,
            searchEnabled: SearchModule.enabled,
            appsEnabled: AppsModule.enabled,
            spaceEnabled: SpaceModule.enabled,
            browserEnabled:BrowserModule.enabled,connectionsEnabled:ConnectionsModule.enabled,historyEnabled:HistoryModule.enabled,agentsEnabled:AgentDiagnosticsModule.enabled,checkupEnabled:CheckupModule.enabled,
            hasBattery: battery,
            keepAwakeActive: IdleAwakeModel.shared.state.phase == .active,
            focusTimerActive: FocusTimerModel.shared.phase.isActive,
            retainedQuickControlsAppear: !retained.isEmpty,
            updatesCanCheck: AppModels.shared.updates.canCheck,
            moreToolsActiveStates: StatusMenuLayout.MoreToolsActiveStates(
                cleanScreenActive: CleanScreenModel.shared.active,
                lowLatencyActive: AWDLModel.shared.state?.phase == .active,
                batteryProtectionActive: battery && (BatteryCareModel.shared.state?.ownedByCaller == true)
            )
        )
        
        let layout=StatusMenuLayout.make(context:context)
        let menu = NSMenu()
        menu.autoenablesItems = false
        
        for productItem in layout.productItems {
            switch productItem {
            case .openThermo:
                menu.addItem(item(tr("Open Thermo"), "macwindow", key: "o") { MainWindow.show() })
                
            case .searchAppsAndFiles:
                menu.addItem(item(tr("Search apps and files"), "magnifyingglass") { SearchModule.show() })
                
            case .nativeMenus:
                for entry in nativeEntries {
                    if let content=AppModels.shared.nativeFeatures.menuContent(entry.ref){NativeMenuRendering.append(to:menu,nodes:content.items(.status),owner:entry.ref)}
                }
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
                menu.addItem(item(tr("Manage menu bar…"), "menubar.rectangle") { _=AppModels.shared.nativeFeatures.activate(.init(BuiltinModuleManifests.menuBar.id,"tools")) })
                
            case .history:
                menu.addItem(page(tr("History"), "clock.arrow.circlepath", .module(BuiltinModuleManifests.history.id,"home")))
                
            case .settings:
                menu.addItem(item(tr("Settings…"), "gearshape", key: ",") { MainWindow.show(.settings) })
            }
        }
        
        menu.addItem(.separator())
        
        Self.appendRetainedControls(to:menu,layout:layout,contributions:retained)
        let footer = layout.retainedExtras.footer
        let check = item(tr(footer.checkForUpdates.title), "arrow.triangle.2.circlepath") { AppModels.shared.updates.checkForUpdates() }
        check.isEnabled = footer.checkForUpdates.enabled
        menu.addItem(check)
        menu.addItem(item(tr(footer.about.title), "info.circle") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        })
        menu.addItem(.separator())
        menu.addItem(item(tr(footer.quit.title), "power", key: "q") { NSApp.terminate(nil) })
        
        return menu
    }
    
    static func appendRetainedControls(to menu:NSMenu,layout:StatusMenuLayout,contributions:[NativeRetainedMenu]) {
        for slot in layout.retainedExtras.quickControls {
            switch slot {case .nativeRetained:
                for contribution in contributions{NativeMenuRendering.append(to:menu,nodes:contribution.content.items(.status),owner:contribution.owner)}
            }
        }
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
            case .overview:
                submenu.addItem(page(tr("Overview"), "gauge.with.dots.needle.67percent", .overview))
            case .aiCheckup:
                submenu.addItem(page(tr("AI Check-up"), "waveform.path.ecg", .module(BuiltinModuleManifests.checkup.id,"home")))
            case .sensors:
                submenu.addItem(page(tr("Sensors"), "thermometer.medium", .sensors))
            case .fans:
                submenu.addItem(page(tr("Fans"), "fan", .fans))
            case .connections:
                submenu.addItem(page(tr("Connections"), "wifi", .module(BuiltinModuleManifests.connections.id,"home")))
            case .cpuUsage:
                submenu.addItem(page(tr("CPU usage"), "cpu", .compute(false)))
            case .gpuUsage:
                submenu.addItem(page(tr("GPU usage"), "square.stack.3d.up", .compute(true)))
            case .memoryUsage:
                submenu.addItem(page(tr("Memory usage"), "memorychip", .memory))
            case .tabOrganizer:
                submenu.addItem(page(tr("Tab organizer"), "rectangle.stack", .browser("Google Chrome")))
            case .smartScan:
                // Keep the saved preference slot; its label, icon and destination come from the registry.
                if let declared = ModuleCenter.shared.legacyMenuPage("smartScan") {
                    submenu.addItem(page(declared.title, declared.symbol, declared.target))
                }
            case .spaceLens:
                submenu.addItem(page(tr("Space Lens"), "square.grid.3x3.topleft.filled", .native(.init(BuiltinModuleManifests.space.id,"browse"))))
            case .software:
                submenu.addItem(page(tr("Software"), "square.grid.2x2", .native(.init(BuiltinModuleManifests.apps.id,"installed"))))
            case .claudeTools:
                submenu.addItem(page(tr("Claude tools"), "person.2", .module(BuiltinModuleManifests.claude.id,"accounts")))
            case .smartCheck:
                submenu.addItem(page(tr("Smart Check"), "stethoscope", .native(.init(BuiltinModuleManifests.agents.id,"home"))))
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
