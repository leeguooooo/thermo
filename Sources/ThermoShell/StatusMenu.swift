import NativeFeatureAPI
import ModuleKit
import ThermoUI
import AppKit
import ThermoKit
import ThermoL10n
import ToolsControlAPI

/// The menu bar tools, reached only through their own module.
@MainActor enum ShellTools {
    static var access: any ToolsApplicationAccess { ShellState.shared.assembly.makeTools(ShellState.shared.nativeFeatures) }
}

/// The menu bar item's menu: every place in the window and every tool, one click away, grouped
/// the way the window's sidebar is (the Mac's state, cleanup, AI agents), then the tools, then the app.
/// Native, so it reads like any other menu on the Mac: a symbol on each row, shortcuts on the right.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    static let shared = StatusMenu()

    func make(battery: Bool) -> NSMenu {
        let nativeEntries=ShellNativeCatalog.catalog.menuEntries.filter{$0.hasContent && ModuleCenter.shared.isOn($0.ref.module)}
        let retained=ShellState.shared.nativeFeatures.retainedMenuContent()
        let tools=ShellTools.access
        
        let context = StatusMenuLayout.RuntimeContext(
            nativeMenusAppear:!nativeEntries.isEmpty,
            menuBarEnabled: ModuleCenter.shared.isOn(BuiltinModuleManifests.menuBar.id),
            performanceEnabled: ModuleCenter.shared.isOn(BuiltinModuleManifests.performance.id),
            searchEnabled: ModuleCenter.shared.isOn(BuiltinModuleManifests.search.id),
            appsEnabled: ModuleCenter.shared.isOn(BuiltinModuleManifests.apps.id),
            spaceEnabled: ModuleCenter.shared.isOn(BuiltinModuleManifests.space.id),
            browserEnabled:ModuleCenter.shared.isOn(BuiltinModuleManifests.browser.id),connectionsEnabled:ModuleCenter.shared.isOn(BuiltinModuleManifests.connections.id),historyEnabled:ModuleCenter.shared.isOn(BuiltinModuleManifests.history.id),agentsEnabled:ModuleCenter.shared.isOn(BuiltinModuleManifests.agents.id),checkupEnabled:ModuleCenter.shared.isOn(BuiltinModuleManifests.checkup.id),
            hasBattery: battery,
            keepAwakeEnabled: ModuleCenter.shared.isOn(ShellTool.keepAwake.manifest.id),
            focusTimerEnabled: ModuleCenter.shared.isOn(ShellTool.focus.manifest.id),
            cleanScreenEnabled: ModuleCenter.shared.isOn(ShellTool.cleanScreen.manifest.id),
            lowLatencyEnabled: ModuleCenter.shared.isOn(ShellTool.lowLatency.manifest.id),
            batteryProtectionEnabled: ModuleCenter.shared.isOn(ShellTool.batteryCare.manifest.id),
            keepAwakeActive: tools.isActive(.keepAwake),
            focusTimerActive: tools.isActive(.focus),
            retainedQuickControlsAppear: !retained.isEmpty,
            updatesCanCheck: ShellState.shared.updates.canCheck,
            moreToolsActiveStates: StatusMenuLayout.MoreToolsActiveStates(
                cleanScreenActive: tools.isActive(.cleanScreen),
                lowLatencyActive: tools.isActive(.lowLatency),
                batteryProtectionActive: battery && tools.isActive(.batteryCare)
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
                menu.addItem(item(tr("Search apps and files"), "magnifyingglass") { SearchHost.show() })
                
            case .nativeMenus:
                for entry in nativeEntries {
                    if let content=ShellState.shared.nativeFeatures.menuContent(entry.ref){NativeMenuRendering.append(to:menu,nodes:content.items(.status),owner:entry.ref)}
                }
            case .menuGroup(let group):
                menu.addItem(materializeGroup(group))
                
            case .directStatusItem(let status):
                let tool: ShellTool? = status.title == "Keep awake" ? .keepAwake : status.title == "Focus timer" ? .focus : nil
                if let tool {
                    let nodes = tools.menu(tool)
                    guard !nodes.isEmpty else { break }
                    let parent = NSMenuItem(title: tr(status.title), action: nil, keyEquivalent: "")
                    parent.image = symbol(tool.manifest.symbol)
                    if status.isActive { parent.state = .on }
                    let sub = NSMenu()
                    NativeMenuRendering.append(to: sub, nodes: nodes, owner: tool.options)
                    parent.submenu = sub
                    menu.addItem(parent)
                }
                
            case .manageMenuBar:
                menu.addItem(item(tr("Manage menu bar…"), "menubar.rectangle") { _=ShellState.shared.nativeFeatures.activate(.init(BuiltinModuleManifests.menuBar.id,"tools")) })
                
            case .history:
                menu.addItem(page(tr("History"), "clock.arrow.circlepath", .native(.init(BuiltinModuleManifests.history.id,"home"))))
                
            case .settings:
                menu.addItem(item(tr("Settings…"), "gearshape", key: ",") { MainWindow.show(.settings) })
            }
        }
        
        menu.addItem(.separator())
        
        Self.appendRetainedControls(to:menu,layout:layout,contributions:retained)
        let footer = layout.retainedExtras.footer
        let check = item(tr(footer.checkForUpdates.title), "arrow.triangle.2.circlepath") { ShellState.shared.updates.checkForUpdates() }
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
                submenu.addItem(page(tr("AI Check-up"), "waveform.path.ecg", .native(.init(BuiltinModuleManifests.checkup.id,"home"))))
            case .sensors:
                submenu.addItem(page(tr("Sensors"), "thermometer.medium", .sensors))
            case .fans:
                submenu.addItem(page(tr("Fans"), "fan", .fans))
            case .connections:
                submenu.addItem(page(tr("Connections"), "wifi", .native(.init(BuiltinModuleManifests.connections.id,"home"))))
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
                submenu.addItem(page(tr("Claude tools"), "person.2", .native(.init(BuiltinModuleManifests.claude.id,"accounts"))))
            case .smartCheck:
                submenu.addItem(page(tr("Smart Check"), "stethoscope", .native(.init(BuiltinModuleManifests.agents.id,"home"))))
            case .cleanScreen:
                NativeMenuRendering.append(to: submenu, nodes: ShellTools.access.menu(.cleanScreen), owner: ShellTool.cleanScreen.options)
            case .networkLowLatency:
                NativeMenuRendering.append(to: submenu, nodes: ShellTools.access.menu(.lowLatency), owner: ShellTool.lowLatency.options)
            case .batteryProtection:
                NativeMenuRendering.append(to: submenu, nodes: ShellTools.access.menu(.batteryCare), owner: ShellTool.batteryCare.options)
            }
        }
        
        parent.submenu = submenu
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
