import Foundation

/// Pure status menu layout structure: 12 product first-level items + retained extras.
/// Input: runtime facts. Output: ordered structure for AppKit materialization.
/// Testable seam for menu tree assertions without AppKit.
@MainActor
struct StatusMenuLayout {
    let productItems: [ProductItem]
    let retainedExtras: RetainedExtras
    
    struct RuntimeContext {
        let hasBattery: Bool
        let keepAwakeActive: Bool
        let focusTimerActive: Bool
        let configuredCaptureEntriesAppear: Bool
        let menuBarQuickControlsAppear: Bool
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
        case showHiddenOrCollapse
        case restoreAllIcons
    }
    
    enum ProductItem {
        case openThermo
        case searchAppsAndFiles
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
        case captureScreen(shortcutSuffix: String)
        case scrollingCapture
        case recordScreen
        case recordingDrafts
        case openImage
        case configuredCaptureActions(entries: [String])
        case captureSavingSettings
        case captureShortcutsSettings
        case pinClipboard(shortcutSuffix: String)
        case pinClipboardAsText
        case pinClipboardAsLaTeX
        case pinGroupsAndHistory
        case restoreLastClosedPin
        case restorePinMouseInteraction
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
            case .captureScreen: return "captureScreen"
            case .scrollingCapture: return "scrollingCapture"
            case .recordScreen: return "recordScreen"
            case .recordingDrafts: return "recordingDrafts"
            case .openImage: return "openImage"
            case .configuredCaptureActions: return "configuredCaptureActions"
            case .captureSavingSettings: return "captureSavingSettings"
            case .captureShortcutsSettings: return "captureShortcutsSettings"
            case .pinClipboard: return "pinClipboard"
            case .pinClipboardAsText: return "pinClipboardAsText"
            case .pinClipboardAsLaTeX: return "pinClipboardAsLaTeX"
            case .pinGroupsAndHistory: return "pinGroupsAndHistory"
            case .restoreLastClosedPin: return "restoreLastClosedPin"
            case .restorePinMouseInteraction: return "restorePinMouseInteraction"
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
    
    static func make(context: RuntimeContext, captureShortcutSuffix: String, pinShortcutSuffix: String, configuredCaptureEntries: [String]) -> StatusMenuLayout {
        var productItems: [ProductItem] = []
        
        // 1. Open Thermo
        productItems.append(.openThermo)
        
        // 2. Search apps and files
        productItems.append(.searchAppsAndFiles)
        
        // 3. Capture & record (Menu Group)
        var captureLeaves: [LeafAction] = [
            .captureScreen(shortcutSuffix: captureShortcutSuffix),
            .scrollingCapture,
            .recordScreen,
            .recordingDrafts,
            .openImage
        ]
        if context.configuredCaptureEntriesAppear && !configuredCaptureEntries.isEmpty {
            captureLeaves.append(.configuredCaptureActions(entries: configuredCaptureEntries))
        }
        captureLeaves.append(.captureSavingSettings)
        captureLeaves.append(.captureShortcutsSettings)
        productItems.append(.menuGroup(MenuGroup(
            title: "Capture & record",
            leaves: captureLeaves,
            hasActiveHint: false
        )))
        
        // 4. Clipboard & pins (Menu Group)
        let clipboardLeaves: [LeafAction] = [
            .pinClipboard(shortcutSuffix: pinShortcutSuffix),
            .pinClipboardAsText,
            .pinClipboardAsLaTeX,
            .pinGroupsAndHistory,
            .restoreLastClosedPin,
            .restorePinMouseInteraction
        ]
        productItems.append(.menuGroup(MenuGroup(
            title: "Clipboard & pins",
            leaves: clipboardLeaves,
            hasActiveHint: false
        )))
        
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
        ]
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
        ]
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
        productItems.append(.manageMenuBar)
        
        // 11. History
        productItems.append(.history)
        
        // 12. Settings…
        productItems.append(.settings)
        
        // Retained extras
        var quickControls: [QuickControl] = []
        if context.menuBarQuickControlsAppear {
            quickControls.append(.showHiddenOrCollapse)
            quickControls.append(.restoreAllIcons)
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
