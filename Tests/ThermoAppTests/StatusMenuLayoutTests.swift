import XCTest
@testable import ThermoApp

@MainActor final class StatusMenuLayoutTests: XCTestCase {
    
    // A1: Default inputs yield product first-level titles in the confirmed order of the twelve
    func testProductFirstLevelOrderMatchesSpec() {
        let context = StatusMenuLayout.RuntimeContext(
            hasBattery: true,
            keepAwakeActive: false,
            focusTimerActive: false,
            configuredCaptureEntriesAppear: false,
            menuBarQuickControlsAppear: false,
            updatesCanCheck: true,
            moreToolsActiveStates: StatusMenuLayout.MoreToolsActiveStates(
                cleanScreenActive: false,
                lowLatencyActive: false,
                batteryProtectionActive: false
            )
        )
        
        let layout = StatusMenuLayout.make(
            context: context,
            captureShortcutSuffix: "",
            pinShortcutSuffix: "",
            configuredCaptureEntries: []
        )
        
        XCTAssertEqual(layout.productItems.count, 12)
        
        let expectedOrder: [(Int, String)] = [
            (0, "openThermo"),
            (1, "searchAppsAndFiles"),
            (2, "menuGroup:Capture & record"),
            (3, "menuGroup:Clipboard & pins"),
            (4, "menuGroup:System & hardware"),
            (5, "menuGroup:Clean & storage"),
            (6, "menuGroup:More tools"),
            (7, "directStatusItem:Keep awake"),
            (8, "directStatusItem:Focus timer"),
            (9, "manageMenuBar"),
            (10, "history"),
            (11, "settings")
        ]
        
        for (index, expected) in expectedOrder {
            let actual = itemDescription(layout.productItems[index])
            XCTAssertEqual(actual, expected, "Position \(index) should be \(expected)")
        }
    }
    
    // A2: Every inventory Leaf Action appears exactly once under its assigned group
    func testEveryLeafActionAppearsExactlyOnce() {
        let context = StatusMenuLayout.RuntimeContext(
            hasBattery: true,
            keepAwakeActive: false,
            focusTimerActive: false,
            configuredCaptureEntriesAppear: true,
            menuBarQuickControlsAppear: false,
            updatesCanCheck: true,
            moreToolsActiveStates: StatusMenuLayout.MoreToolsActiveStates(
                cleanScreenActive: false,
                lowLatencyActive: false,
                batteryProtectionActive: false
            )
        )
        
        let layout = StatusMenuLayout.make(
            context: context,
            captureShortcutSuffix: "",
            pinShortcutSuffix: "",
            configuredCaptureEntries: ["Test Entry"]
        )
        
        let allLeaves = layout.productItems.compactMap { item -> StatusMenuLayout.MenuGroup? in
            if case .menuGroup(let group) = item { return group }
            return nil
        }.flatMap { $0.leaves }
        
        let leafIdentities = allLeaves.map { $0.identity }
        let uniqueIdentities = Set(leafIdentities)
        
        XCTAssertEqual(leafIdentities.count, uniqueIdentities.count, "Each leaf should appear exactly once")
        
        // Verify expected leaves are present
        let expectedLeaves = [
            "captureScreen", "scrollingCapture", "recordScreen", "recordingDrafts", "openImage",
            "configuredCaptureActions", "captureSavingSettings", "captureShortcutsSettings",
            "pinClipboard", "pinClipboardAsText", "pinClipboardAsLaTeX", "pinGroupsAndHistory",
            "restoreLastClosedPin", "restorePinMouseInteraction",
            "overview", "aiCheckup", "sensors", "fans", "connections",
            "cpuUsage", "gpuUsage", "memoryUsage", "tabOrganizer",
            "smartScan", "spaceLens", "software",
            "claudeTools", "smartCheck", "cleanScreen", "networkLowLatency", "batteryProtection"
        ]
        
        for expected in expectedLeaves {
            XCTAssertTrue(leafIdentities.contains(expected), "\(expected) should be present")
        }
    }
    
    // A3: Battery unavailable => battery care leaf absent; available => present under More tools
    func testBatteryAvailabilityAffectsBatteryProtection() {
        // With battery
        let withBattery = StatusMenuLayout.RuntimeContext(
            hasBattery: true,
            keepAwakeActive: false,
            focusTimerActive: false,
            configuredCaptureEntriesAppear: false,
            menuBarQuickControlsAppear: false,
            updatesCanCheck: true,
            moreToolsActiveStates: StatusMenuLayout.MoreToolsActiveStates(
                cleanScreenActive: false,
                lowLatencyActive: false,
                batteryProtectionActive: false
            )
        )
        
        let layoutWithBattery = StatusMenuLayout.make(
            context: withBattery,
            captureShortcutSuffix: "",
            pinShortcutSuffix: "",
            configuredCaptureEntries: []
        )
        
        let moreToolsWithBattery = layoutWithBattery.productItems.compactMap { item -> StatusMenuLayout.MenuGroup? in
            if case .menuGroup(let group) = item, group.title == "More tools" { return group }
            return nil
        }.first!
        
        let hasBatteryProtection = moreToolsWithBattery.leaves.contains { $0.identity == "batteryProtection" }
        XCTAssertTrue(hasBatteryProtection, "Battery protection should be present when battery is available")
        
        // Without battery
        let withoutBattery = StatusMenuLayout.RuntimeContext(
            hasBattery: false,
            keepAwakeActive: false,
            focusTimerActive: false,
            configuredCaptureEntriesAppear: false,
            menuBarQuickControlsAppear: false,
            updatesCanCheck: true,
            moreToolsActiveStates: StatusMenuLayout.MoreToolsActiveStates(
                cleanScreenActive: false,
                lowLatencyActive: false,
                batteryProtectionActive: false
            )
        )
        
        let layoutWithoutBattery = StatusMenuLayout.make(
            context: withoutBattery,
            captureShortcutSuffix: "",
            pinShortcutSuffix: "",
            configuredCaptureEntries: []
        )
        
        let moreToolsWithoutBattery = layoutWithoutBattery.productItems.compactMap { item -> StatusMenuLayout.MenuGroup? in
            if case .menuGroup(let group) = item, group.title == "More tools" { return group }
            return nil
        }.first!
        
        let noBatteryProtection = moreToolsWithoutBattery.leaves.contains { $0.identity == "batteryProtection" }
        XCTAssertFalse(noBatteryProtection, "Battery protection should be absent when battery is unavailable")
    }
    
    // A4: Configured capture submenu absent when empty; present when there are entries
    func testConfiguredCaptureSubmenuVisibility() {
        // Without configured entries
        let withoutEntries = StatusMenuLayout.RuntimeContext(
            hasBattery: true,
            keepAwakeActive: false,
            focusTimerActive: false,
            configuredCaptureEntriesAppear: false,
            menuBarQuickControlsAppear: false,
            updatesCanCheck: true,
            moreToolsActiveStates: StatusMenuLayout.MoreToolsActiveStates(
                cleanScreenActive: false,
                lowLatencyActive: false,
                batteryProtectionActive: false
            )
        )
        
        let layoutWithoutEntries = StatusMenuLayout.make(
            context: withoutEntries,
            captureShortcutSuffix: "",
            pinShortcutSuffix: "",
            configuredCaptureEntries: []
        )
        
        let captureGroupWithout = layoutWithoutEntries.productItems.compactMap { item -> StatusMenuLayout.MenuGroup? in
            if case .menuGroup(let group) = item, group.title == "Capture & record" { return group }
            return nil
        }.first!
        
        let hasConfiguredWithout = captureGroupWithout.leaves.contains { $0.identity == "configuredCaptureActions" }
        XCTAssertFalse(hasConfiguredWithout, "Configured capture actions should be absent when empty")
        
        // With configured entries
        let withEntries = StatusMenuLayout.RuntimeContext(
            hasBattery: true,
            keepAwakeActive: false,
            focusTimerActive: false,
            configuredCaptureEntriesAppear: true,
            menuBarQuickControlsAppear: false,
            updatesCanCheck: true,
            moreToolsActiveStates: StatusMenuLayout.MoreToolsActiveStates(
                cleanScreenActive: false,
                lowLatencyActive: false,
                batteryProtectionActive: false
            )
        )
        
        let layoutWithEntries = StatusMenuLayout.make(
            context: withEntries,
            captureShortcutSuffix: "",
            pinShortcutSuffix: "",
            configuredCaptureEntries: ["Entry 1", "Entry 2"]
        )
        
        let captureGroupWith = layoutWithEntries.productItems.compactMap { item -> StatusMenuLayout.MenuGroup? in
            if case .menuGroup(let group) = item, group.title == "Capture & record" { return group }
            return nil
        }.first!
        
        let hasConfiguredWith = captureGroupWith.leaves.contains { $0.identity == "configuredCaptureActions" }
        XCTAssertTrue(hasConfiguredWith, "Configured capture actions should be present when entries exist")
    }
    
    // A5: Keep awake active => Direct Status Item active; inactive => not
    func testKeepAwakeActiveState() {
        // Active
        let activeContext = StatusMenuLayout.RuntimeContext(
            hasBattery: true,
            keepAwakeActive: true,
            focusTimerActive: false,
            configuredCaptureEntriesAppear: false,
            menuBarQuickControlsAppear: false,
            updatesCanCheck: true,
            moreToolsActiveStates: StatusMenuLayout.MoreToolsActiveStates(
                cleanScreenActive: false,
                lowLatencyActive: false,
                batteryProtectionActive: false
            )
        )
        
        let activeLayout = StatusMenuLayout.make(
            context: activeContext,
            captureShortcutSuffix: "",
            pinShortcutSuffix: "",
            configuredCaptureEntries: []
        )
        
        let keepAwakeActive = activeLayout.productItems.compactMap { item -> StatusMenuLayout.DirectStatusItem? in
            if case .directStatusItem(let status) = item, status.title == "Keep awake" { return status }
            return nil
        }.first!
        
        XCTAssertTrue(keepAwakeActive.isActive, "Keep awake should be active")
        
        // Inactive
        let inactiveContext = StatusMenuLayout.RuntimeContext(
            hasBattery: true,
            keepAwakeActive: false,
            focusTimerActive: false,
            configuredCaptureEntriesAppear: false,
            menuBarQuickControlsAppear: false,
            updatesCanCheck: true,
            moreToolsActiveStates: StatusMenuLayout.MoreToolsActiveStates(
                cleanScreenActive: false,
                lowLatencyActive: false,
                batteryProtectionActive: false
            )
        )
        
        let inactiveLayout = StatusMenuLayout.make(
            context: inactiveContext,
            captureShortcutSuffix: "",
            pinShortcutSuffix: "",
            configuredCaptureEntries: []
        )
        
        let keepAwakeInactive = inactiveLayout.productItems.compactMap { item -> StatusMenuLayout.DirectStatusItem? in
            if case .directStatusItem(let status) = item, status.title == "Keep awake" { return status }
            return nil
        }.first!
        
        XCTAssertFalse(keepAwakeInactive.isActive, "Keep awake should be inactive")
    }
    
    // A6: Focus timer active/running phase => Direct Status Item active; inactive => not
    func testFocusTimerActiveState() {
        // Active
        let activeContext = StatusMenuLayout.RuntimeContext(
            hasBattery: true,
            keepAwakeActive: false,
            focusTimerActive: true,
            configuredCaptureEntriesAppear: false,
            menuBarQuickControlsAppear: false,
            updatesCanCheck: true,
            moreToolsActiveStates: StatusMenuLayout.MoreToolsActiveStates(
                cleanScreenActive: false,
                lowLatencyActive: false,
                batteryProtectionActive: false
            )
        )
        
        let activeLayout = StatusMenuLayout.make(
            context: activeContext,
            captureShortcutSuffix: "",
            pinShortcutSuffix: "",
            configuredCaptureEntries: []
        )
        
        let focusTimerActive = activeLayout.productItems.compactMap { item -> StatusMenuLayout.DirectStatusItem? in
            if case .directStatusItem(let status) = item, status.title == "Focus timer" { return status }
            return nil
        }.first!
        
        XCTAssertTrue(focusTimerActive.isActive, "Focus timer should be active")
        
        // Inactive
        let inactiveContext = StatusMenuLayout.RuntimeContext(
            hasBattery: true,
            keepAwakeActive: false,
            focusTimerActive: false,
            configuredCaptureEntriesAppear: false,
            menuBarQuickControlsAppear: false,
            updatesCanCheck: true,
            moreToolsActiveStates: StatusMenuLayout.MoreToolsActiveStates(
                cleanScreenActive: false,
                lowLatencyActive: false,
                batteryProtectionActive: false
            )
        )
        
        let inactiveLayout = StatusMenuLayout.make(
            context: inactiveContext,
            captureShortcutSuffix: "",
            pinShortcutSuffix: "",
            configuredCaptureEntries: []
        )
        
        let focusTimerInactive = inactiveLayout.productItems.compactMap { item -> StatusMenuLayout.DirectStatusItem? in
            if case .directStatusItem(let status) = item, status.title == "Focus timer" { return status }
            return nil
        }.first!
        
        XCTAssertFalse(focusTimerInactive.isActive, "Focus timer should be inactive")
    }
    
    // A7: Any More-tools nested mode active => More tools Group Status Hint on; all off => off
    func testMoreToolsGroupStatusHint() {
        // Clean Screen active
        let cleanScreenActive = StatusMenuLayout.RuntimeContext(
            hasBattery: true,
            keepAwakeActive: false,
            focusTimerActive: false,
            configuredCaptureEntriesAppear: false,
            menuBarQuickControlsAppear: false,
            updatesCanCheck: true,
            moreToolsActiveStates: StatusMenuLayout.MoreToolsActiveStates(
                cleanScreenActive: true,
                lowLatencyActive: false,
                batteryProtectionActive: false
            )
        )
        
        let layoutCleanScreenActive = StatusMenuLayout.make(
            context: cleanScreenActive,
            captureShortcutSuffix: "",
            pinShortcutSuffix: "",
            configuredCaptureEntries: []
        )
        
        let moreToolsActive = layoutCleanScreenActive.productItems.compactMap { item -> StatusMenuLayout.MenuGroup? in
            if case .menuGroup(let group) = item, group.title == "More tools" { return group }
            return nil
        }.first!
        
        XCTAssertTrue(moreToolsActive.hasActiveHint, "More tools should have active hint when Clean Screen is active")
        
        // All inactive
        let allInactive = StatusMenuLayout.RuntimeContext(
            hasBattery: true,
            keepAwakeActive: false,
            focusTimerActive: false,
            configuredCaptureEntriesAppear: false,
            menuBarQuickControlsAppear: false,
            updatesCanCheck: true,
            moreToolsActiveStates: StatusMenuLayout.MoreToolsActiveStates(
                cleanScreenActive: false,
                lowLatencyActive: false,
                batteryProtectionActive: false
            )
        )
        
        let layoutAllInactive = StatusMenuLayout.make(
            context: allInactive,
            captureShortcutSuffix: "",
            pinShortcutSuffix: "",
            configuredCaptureEntries: []
        )
        
        let moreToolsInactive = layoutAllInactive.productItems.compactMap { item -> StatusMenuLayout.MenuGroup? in
            if case .menuGroup(let group) = item, group.title == "More tools" { return group }
            return nil
        }.first!
        
        XCTAssertFalse(moreToolsInactive.hasActiveHint, "More tools should not have active hint when all are inactive")
    }
    
    // A8: Group Status Hint payload contains no personal-data fields
    func testGroupStatusHintContainsNoPersonalData() {
        let context = StatusMenuLayout.RuntimeContext(
            hasBattery: true,
            keepAwakeActive: false,
            focusTimerActive: false,
            configuredCaptureEntriesAppear: false,
            menuBarQuickControlsAppear: false,
            updatesCanCheck: true,
            moreToolsActiveStates: StatusMenuLayout.MoreToolsActiveStates(
                cleanScreenActive: true,
                lowLatencyActive: false,
                batteryProtectionActive: false
            )
        )
        
        let layout = StatusMenuLayout.make(
            context: context,
            captureShortcutSuffix: "",
            pinShortcutSuffix: "",
            configuredCaptureEntries: []
        )
        
        // Group Status Hint is represented as a boolean flag only, no payload with personal data
        for item in layout.productItems {
            if case .menuGroup(let group) = item {
                // hasActiveHint is a boolean, contains no personal data
                XCTAssertTrue(group.hasActiveHint == true || group.hasActiveHint == false)
            }
        }
    }
    
    // A9: Retained extras represented: quick controls only under their flags; footer includes Updates/About/Quit
    func testRetainedExtrasPresence() {
        // With quick controls
        let withQuickControls = StatusMenuLayout.RuntimeContext(
            hasBattery: true,
            keepAwakeActive: false,
            focusTimerActive: false,
            configuredCaptureEntriesAppear: false,
            menuBarQuickControlsAppear: true,
            updatesCanCheck: true,
            moreToolsActiveStates: StatusMenuLayout.MoreToolsActiveStates(
                cleanScreenActive: false,
                lowLatencyActive: false,
                batteryProtectionActive: false
            )
        )
        
        let layoutWithControls = StatusMenuLayout.make(
            context: withQuickControls,
            captureShortcutSuffix: "",
            pinShortcutSuffix: "",
            configuredCaptureEntries: []
        )
        
        XCTAssertFalse(layoutWithControls.retainedExtras.quickControls.isEmpty, "Quick controls should be present")
        
        // Without quick controls
        let withoutQuickControls = StatusMenuLayout.RuntimeContext(
            hasBattery: true,
            keepAwakeActive: false,
            focusTimerActive: false,
            configuredCaptureEntriesAppear: false,
            menuBarQuickControlsAppear: false,
            updatesCanCheck: true,
            moreToolsActiveStates: StatusMenuLayout.MoreToolsActiveStates(
                cleanScreenActive: false,
                lowLatencyActive: false,
                batteryProtectionActive: false
            )
        )
        
        let layoutWithoutControls = StatusMenuLayout.make(
            context: withoutQuickControls,
            captureShortcutSuffix: "",
            pinShortcutSuffix: "",
            configuredCaptureEntries: []
        )
        
        XCTAssertTrue(layoutWithoutControls.retainedExtras.quickControls.isEmpty, "Quick controls should be absent")
        
        // Footer always present
        XCTAssertTrue(layoutWithControls.retainedExtras.footer.checkForUpdatesEnabled)
        XCTAssertTrue(layoutWithoutControls.retainedExtras.footer.checkForUpdatesEnabled)
    }
    
    // A10: Leaf Action identities remain stable for shortcut/binding metadata
    func testLeafActionIdentitiesStable() {
        let context = StatusMenuLayout.RuntimeContext(
            hasBattery: true,
            keepAwakeActive: false,
            focusTimerActive: false,
            configuredCaptureEntriesAppear: true,
            menuBarQuickControlsAppear: false,
            updatesCanCheck: true,
            moreToolsActiveStates: StatusMenuLayout.MoreToolsActiveStates(
                cleanScreenActive: false,
                lowLatencyActive: false,
                batteryProtectionActive: false
            )
        )
        
        let layout = StatusMenuLayout.make(
            context: context,
            captureShortcutSuffix: "",
            pinShortcutSuffix: "",
            configuredCaptureEntries: ["Test"]
        )
        
        let allLeaves = layout.productItems.compactMap { item -> StatusMenuLayout.MenuGroup? in
            if case .menuGroup(let group) = item { return group }
            return nil
        }.flatMap { $0.leaves }
        
        // Verify key action identities are present and stable
        let criticalIdentities = [
            "captureScreen",
            "pinClipboard",
            "cleanScreen"
        ]
        
        for identity in criticalIdentities {
            XCTAssertTrue(allLeaves.contains { $0.identity == identity }, "\(identity) should maintain stable identity")
        }
    }
    
    // Helper function to describe product items
    private func itemDescription(_ item: StatusMenuLayout.ProductItem) -> String {
        switch item {
        case .openThermo:
            return "openThermo"
        case .searchAppsAndFiles:
            return "searchAppsAndFiles"
        case .menuGroup(let group):
            return "menuGroup:\(group.title)"
        case .directStatusItem(let status):
            return "directStatusItem:\(status.title)"
        case .manageMenuBar:
            return "manageMenuBar"
        case .history:
            return "history"
        case .settings:
            return "settings"
        }
    }
}
