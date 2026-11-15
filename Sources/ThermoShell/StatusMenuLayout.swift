import Foundation

/// Pure status menu layout with a feature-owned menu insertion point.
/// Input: runtime facts. Output: ordered structure for AppKit materialization.
/// Testable seam for menu tree assertions without AppKit.
@MainActor
struct StatusMenuLayout {
    let productItems: [ProductItem]
    let retainedExtras: RetainedExtras
    
    struct RuntimeContext {
        var nativeMenusAppear:Bool = true
        var menuBarEnabled: Bool = true
        var performanceEnabled: Bool = true
        var searchEnabled: Bool = true
        var appsEnabled: Bool = true
        var spaceEnabled: Bool = true
        var browserEnabled:Bool = true
        var connectionsEnabled:Bool = true
        var historyEnabled:Bool = true
        var agentsEnabled:Bool = true
        var checkupEnabled:Bool = true
        let hasBattery: Bool
        let keepAwakeActive: Bool
        let focusTimerActive: Bool
        let retainedQuickControlsAppear: Bool
        let updatesCanCheck: Bool
        let moreToolsActiveStates: MoreToolsActiveStates
    }
    
    struct MoreToolsActiveStates {
        let cleanScreenActive: Bool
        let lowLatencyActive: Bool
        let batteryProtectionActive: Bool
    }
    
    struct RetainedExtras {
        let quickControls: [QuickControl]
        let footer: Footer
    }
    
    struct Footer {
        let checkForUpdates: FooterItem
        let about: FooterItem
        let quit: FooterItem
        
        struct FooterItem {
            let title: String
            let enabled: Bool
        }
    }
    
    enum QuickControl {
        case nativeRetained
    }
    
    enum ProductItem {
        case openThermo
        case searchAppsAndFiles
        case nativeMenus
        case menuGroup(MenuGroup)
        case directStatusItem(DirectStatusItem)
        case manageMenuBar
        case history
        case settings
    }
    
    struct MenuGroup {
        let title: String
        let leaves: [LeafAction]
        let hasActiveHint: Bool
    }
    
    struct DirectStatusItem {
        let title: String
        let isActive: Bool
        let submenuActions: [String]
    }
    
    enum LeafAction {
        case overview
        case aiCheckup
        case sensors
        case fans
        case connections
        case cpuUsage
        case gpuUsage
        case memoryUsage
        case tabOrganizer
        case smartScan
        case spaceLens
        case software
        case claudeTools
        case smartCheck
        case cleanScreen
        case networkLowLatency
        case batteryProtection
        
        var identity: String {
            switch self {
            case .overview: return "overview"
            case .aiCheckup: return "aiCheckup"
            case .sensors: return "sensors"
            case .fans: return "fans"
            case .connections: return "connections"
            case .cpuUsage: return "cpuUsage"
            case .gpuUsage: return "gpuUsage"
            case .memoryUsage: return "memoryUsage"
            case .tabOrganizer: return "tabOrganizer"
            case .smartScan: return "smartScan"
            case .spaceLens: return "spaceLens"
            case .software: return "software"
            case .claudeTools: return "claudeTools"
            case .smartCheck: return "smartCheck"
            case .cleanScreen: return "cleanScreen"
            case .networkLowLatency: return "networkLowLatency"
            case .batteryProtection: return "batteryProtection"
            }
        }
    }
    
    static func make(context:RuntimeContext) -> StatusMenuLayout {
        var productItems: [ProductItem] = []
        
        // 1. Open Thermo
        productItems.append(.openThermo)
        
        // 2. Search apps and files
        if context.searchEnabled { productItems.append(.searchAppsAndFiles) }
        
        if context.nativeMenusAppear{productItems.append(.nativeMenus)}

        // 5. System & hardware (Menu Group)
        let systemLeaves: [LeafAction] = [
            .overview,
            .aiCheckup,
            .sensors,
            .fans,
            .connections,
            .cpuUsage,
            .gpuUsage,
            .memoryUsage,
            .tabOrganizer
        ].filter { item in
            switch item {
            case .overview, .sensors, .fans, .cpuUsage, .gpuUsage, .memoryUsage: return context.performanceEnabled
            case .tabOrganizer:return context.browserEnabled
            case .connections:return context.connectionsEnabled
            case .aiCheckup:return context.checkupEnabled
            default: return true
            }
        }
        productItems.append(.menuGroup(MenuGroup(
            title: "System & hardware",
            leaves: systemLeaves,
            hasActiveHint: false
        )))
        
        // 6. Clean & storage (Menu Group)
        let cleanLeaves: [LeafAction] = [
            .smartScan,
            .spaceLens,
            .software
        ].filter { item in
            switch item {
            case .software:return context.appsEnabled
            case .spaceLens:return context.spaceEnabled
            default:return true
            }
        }
        productItems.append(.menuGroup(MenuGroup(
            title: "Clean & storage",
            leaves: cleanLeaves,
            hasActiveHint: false
        )))
        
        // 7. More tools (Menu Group)
        var moreToolsLeaves: [LeafAction] = [
            .claudeTools,
            .smartCheck,
            .cleanScreen,
            .networkLowLatency
        ]
        if context.hasBattery {
            moreToolsLeaves.append(.batteryProtection)
        }
        moreToolsLeaves.removeAll{if case .smartCheck=$0{return !context.agentsEnabled};return false}
        let moreToolsActive = context.moreToolsActiveStates.cleanScreenActive ||
                               context.moreToolsActiveStates.lowLatencyActive ||
                               (context.hasBattery && context.moreToolsActiveStates.batteryProtectionActive)
        productItems.append(.menuGroup(MenuGroup(
            title: "More tools",
            leaves: moreToolsLeaves,
            hasActiveHint: moreToolsActive
        )))
        
        // 8. Keep awake (Direct Status Item)
        productItems.append(.directStatusItem(DirectStatusItem(
            title: "Keep awake",
            isActive: context.keepAwakeActive,
            submenuActions: []
        )))
        
        // 9. Focus timer (Direct Status Item)
        productItems.append(.directStatusItem(DirectStatusItem(
            title: "Focus timer",
            isActive: context.focusTimerActive,
            submenuActions: []
        )))
        
        // 10. Manage menu bar…
        if context.menuBarEnabled { productItems.append(.manageMenuBar) }
        
        // 11. History
        if context.historyEnabled {productItems.append(.history)}
        
        // 12. Settings…
        productItems.append(.settings)
        
        // Retained extras
        var quickControls: [QuickControl] = []
        if context.retainedQuickControlsAppear {
            quickControls.append(.nativeRetained)
        }
        
        let retainedExtras = RetainedExtras(
            quickControls: quickControls,
            footer: Footer(
                checkForUpdates: Footer.FooterItem(title: "Check for Updates…", enabled: context.updatesCanCheck),
                about: Footer.FooterItem(title: "About Thermo", enabled: true),
                quit: Footer.FooterItem(title: "Quit Thermo", enabled: true)
            )
        )
        
        return StatusMenuLayout(productItems: productItems, retainedExtras: retainedExtras)
    }
}
