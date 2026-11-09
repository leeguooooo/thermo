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
        
        // Collect all groups with their leaves
        var groupsByTitle: [String: [String]] = [:]
        for item in layout.productItems {
            if case .menuGroup(let group) = item {
                groupsByTitle[group.title] = group.leaves.map { $0.identity }
            }
        }
        
        // Verify each leaf appears exactly once across all groups
        let allLeaves = groupsByTitle.values.flatMap { $0 }
        let uniqueIdentities = Set(allLeaves)
        XCTAssertEqual(allLeaves.count, uniqueIdentities.count, "Each leaf should appear exactly once")
        
        // Verify group membership: each leaf in its assigned group
        let captureGroup = groupsByTitle["Capture & record"] ?? []
        XCTAssertTrue(captureGroup.contains("captureScreen"), "captureScreen should be in Capture & record")
        XCTAssertTrue(captureGroup.contains("scrollingCapture"), "scrollingCapture should be in Capture & record")
        XCTAssertTrue(captureGroup.contains("recordScreen"), "recordScreen should be in Capture & record")
        XCTAssertTrue(captureGroup.contains("recordingDrafts"), "recordingDrafts should be in Capture & record")
        XCTAssertTrue(captureGroup.contains("openImage"), "openImage should be in Capture & record")
        XCTAssertTrue(captureGroup.contains("configuredCaptureActions"), "configuredCaptureActions should be in Capture & record")
        XCTAssertTrue(captureGroup.contains("captureSavingSettings"), "captureSavingSettings should be in Capture & record")
        XCTAssertTrue(captureGroup.contains("captureShortcutsSettings"), "captureShortcutsSettings should be in Capture & record")
        
        let clipboardGroup = groupsByTitle["Clipboard & pins"] ?? []
        XCTAssertTrue(clipboardGroup.contains("pinClipboard"), "pinClipboard should be in Clipboard & pins")
        XCTAssertTrue(clipboardGroup.contains("pinClipboardAsText"), "pinClipboardAsText should be in Clipboard & pins")
        XCTAssertTrue(clipboardGroup.contains("pinClipboardAsLaTeX"), "pinClipboardAsLaTeX should be in Clipboard & pins")
        XCTAssertTrue(clipboardGroup.contains("pinGroupsAndHistory"), "pinGroupsAndHistory should be in Clipboard & pins")
        XCTAssertTrue(clipboardGroup.contains("restoreLastClosedPin"), "restoreLastClosedPin should be in Clipboard & pins")
        XCTAssertTrue(clipboardGroup.contains("restorePinMouseInteraction"), "restorePinMouseInteraction should be in Clipboard & pins")
        
        let systemGroup = groupsByTitle["System & hardware"] ?? []
        XCTAssertTrue(systemGroup.contains("overview"), "overview should be in System & hardware")
        XCTAssertTrue(systemGroup.contains("aiCheckup"), "aiCheckup should be in System & hardware")
        XCTAssertTrue(systemGroup.contains("sensors"), "sensors should be in System & hardware")
        XCTAssertTrue(systemGroup.contains("fans"), "fans should be in System & hardware")
        XCTAssertTrue(systemGroup.contains("connections"), "connections should be in System & hardware")
        XCTAssertTrue(systemGroup.contains("cpuUsage"), "cpuUsage should be in System & hardware")
        XCTAssertTrue(systemGroup.contains("gpuUsage"), "gpuUsage should be in System & hardware")
        XCTAssertTrue(systemGroup.contains("memoryUsage"), "memoryUsage should be in System & hardware")
        XCTAssertTrue(systemGroup.contains("tabOrganizer"), "tabOrganizer should be in System & hardware")
        
        let cleanGroup = groupsByTitle["Clean & storage"] ?? []
        XCTAssertTrue(cleanGroup.contains("smartScan"), "smartScan should be in Clean & storage")
        XCTAssertTrue(cleanGroup.contains("spaceLens"), "spaceLens should be in Clean & storage")
        XCTAssertTrue(cleanGroup.contains("software"), "software should be in Clean & storage")
        
        let moreToolsGroup = groupsByTitle["More tools"] ?? []
        XCTAssertTrue(moreToolsGroup.contains("claudeTools"), "claudeTools should be in More tools")
        XCTAssertTrue(moreToolsGroup.contains("smartCheck"), "smartCheck should be in More tools")
        XCTAssertTrue(moreToolsGroup.contains("cleanScreen"), "cleanScreen should be in More tools")
        XCTAssertTrue(moreToolsGroup.contains("networkLowLatency"), "networkLowLatency should be in More tools")
        XCTAssertTrue(moreToolsGroup.contains("batteryProtection"), "batteryProtection should be in More tools")
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
        
        // Network low latency active
        let lowLatencyActive = StatusMenuLayout.RuntimeContext(
            hasBattery: true,
            keepAwakeActive: false,
            focusTimerActive: false,
            configuredCaptureEntriesAppear: false,
            menuBarQuickControlsAppear: false,
            updatesCanCheck: true,
            moreToolsActiveStates: StatusMenuLayout.MoreToolsActiveStates(
                cleanScreenActive: false,
                lowLatencyActive: true,
                batteryProtectionActive: false
            )
        )
        
        let layoutLowLatencyActive = StatusMenuLayout.make(
            context: lowLatencyActive,
            captureShortcutSuffix: "",
            pinShortcutSuffix: "",
            configuredCaptureEntries: []
        )
        
        let moreToolsLowLatency = layoutLowLatencyActive.productItems.compactMap { item -> StatusMenuLayout.MenuGroup? in
            if case .menuGroup(let group) = item, group.title == "More tools" { return group }
            return nil
        }.first!
        
        XCTAssertTrue(moreToolsLowLatency.hasActiveHint, "More tools should have active hint when low latency is active")
        
        // Battery protection active (when battery available)
        let batteryProtectionActive = StatusMenuLayout.RuntimeContext(
            hasBattery: true,
            keepAwakeActive: false,
            focusTimerActive: false,
            configuredCaptureEntriesAppear: false,
            menuBarQuickControlsAppear: false,
            updatesCanCheck: true,
            moreToolsActiveStates: StatusMenuLayout.MoreToolsActiveStates(
                cleanScreenActive: false,
                lowLatencyActive: false,
                batteryProtectionActive: true
            )
        )
        
        let layoutBatteryProtectionActive = StatusMenuLayout.make(
            context: batteryProtectionActive,
            captureShortcutSuffix: "",
            pinShortcutSuffix: "",
            configuredCaptureEntries: []
        )
        
        let moreToolsBatteryProtection = layoutBatteryProtectionActive.productItems.compactMap { item -> StatusMenuLayout.MenuGroup? in
            if case .menuGroup(let group) = item, group.title == "More tools" { return group }
            return nil
        }.first!
        
        XCTAssertTrue(moreToolsBatteryProtection.hasActiveHint, "More tools should have active hint when battery protection is active")
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
        
        // Group Status Hint is represented as a boolean flag only (hasActiveHint: Bool).
        // The structure has no string fields, user content fields, or path-like fields
        // that could contain personal data. We verify the hint is purely structural state.
        for item in layout.productItems {
            if case .menuGroup(let group) = item {
                // Verify hasActiveHint is a Bool type (structural constraint)
                let hintValue: Bool = group.hasActiveHint
                _ = hintValue  // Type constraint ensures this is Bool, not a string/path/user content type
                
                // Verify group title is from fixed inventory (not user-provided)
                let knownGroupTitles = ["Capture & record", "Clipboard & pins", "System & hardware", 
                                       "Clean & storage", "More tools"]
                XCTAssertTrue(knownGroupTitles.contains(group.title), 
                             "Group title must be from fixed inventory, not user content")
                
                // Verify all leaf identities are from fixed enum, not user-provided strings
                for leaf in group.leaves {
                    let identity = leaf.identity
                    XCTAssertFalse(identity.contains("/"), "Leaf identity should not contain path separators")
                    XCTAssertFalse(identity.contains("~"), "Leaf identity should not contain home directory markers")
                    XCTAssertTrue(identity.first?.isLowercase ?? false, 
                                 "Leaf identity should follow camelCase enum convention, not be free-form user text")
                }
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
        
        // Footer always present with three members: Check for Updates, About Thermo, Quit Thermo
        // Verify structure and order
        let footer = layoutWithControls.retainedExtras.footer
        XCTAssertEqual(footer.checkForUpdates.title, "Check for Updates…", "Check for Updates title should match")
        XCTAssertEqual(footer.about.title, "About Thermo", "About title should match")
        XCTAssertEqual(footer.quit.title, "Quit Thermo", "Quit title should match")
        
        // Verify Check for Updates enablement follows context
        XCTAssertTrue(footer.checkForUpdates.enabled, "Check for Updates should be enabled when updatesCanCheck is true")
        
        // About and Quit are always enabled
        XCTAssertTrue(footer.about.enabled, "About should always be enabled")
        XCTAssertTrue(footer.quit.enabled, "Quit should always be enabled")
        
        // Test when updates cannot check
        let withoutUpdates = StatusMenuLayout.RuntimeContext(
            hasBattery: true,
            keepAwakeActive: false,
            focusTimerActive: false,
            configuredCaptureEntriesAppear: false,
            menuBarQuickControlsAppear: false,
            updatesCanCheck: false,
            moreToolsActiveStates: StatusMenuLayout.MoreToolsActiveStates(
                cleanScreenActive: false,
                lowLatencyActive: false,
                batteryProtectionActive: false
            )
        )
        
        let layoutWithoutUpdates = StatusMenuLayout.make(
            context: withoutUpdates,
            captureShortcutSuffix: "",
            pinShortcutSuffix: "",
            configuredCaptureEntries: []
        )
        
        XCTAssertFalse(layoutWithoutUpdates.retainedExtras.footer.checkForUpdates.enabled, 
                      "Check for Updates should be disabled when updatesCanCheck is false")
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
            captureShortcutSuffix: " ⌘⇧5",
            pinShortcutSuffix: " ⌘⇧V",
            configuredCaptureEntries: ["Test"]
        )
        
        let allLeaves = layout.productItems.compactMap { item -> StatusMenuLayout.MenuGroup? in
            if case .menuGroup(let group) = item { return group }
            return nil
        }.flatMap { $0.leaves }
        
        let identities = Set(allLeaves.map { $0.identity })
        
        // Baseline identity set from task specification inventory (verified against upstream a9f9340ccd...)
        // This is the complete inventory that must remain stable for shortcut/binding preservation
        let baselineIdentities: Set<String> = [
            "captureScreen", "scrollingCapture", "recordScreen", "recordingDrafts", "openImage",
            "configuredCaptureActions", "captureSavingSettings", "captureShortcutsSettings",
            "pinClipboard", "pinClipboardAsText", "pinClipboardAsLaTeX", "pinGroupsAndHistory",
            "restoreLastClosedPin", "restorePinMouseInteraction",
            "overview", "aiCheckup", "sensors", "fans", "connections",
            "cpuUsage", "gpuUsage", "memoryUsage", "tabOrganizer",
            "smartScan", "spaceLens", "software",
            "claudeTools", "smartCheck", "cleanScreen", "networkLowLatency", "batteryProtection"
        ]
        
        // Verify current layout matches baseline identity set
        XCTAssertEqual(identities, baselineIdentities, "Leaf action identities must remain stable with baseline mapping")
        
        // Verify shortcut-bearing actions preserve their suffix field structure
        // (Full keyEquivalent/selector binding verification requires AppKit adapter, marked UNVERIFIED at seam)
        let captureScreenLeaf = allLeaves.first { $0.identity == "captureScreen" }
        let pinClipboardLeaf = allLeaves.first { $0.identity == "pinClipboard" }
        
        XCTAssertNotNil(captureScreenLeaf, "captureScreen must be present")
        XCTAssertNotNil(pinClipboardLeaf, "pinClipboard must be present")
        
        if case .captureScreen(let suffix) = captureScreenLeaf {
            XCTAssertEqual(suffix, " ⌘⇧5", "captureScreen shortcut suffix should be preserved in structure")
        } else {
            XCTFail("captureScreen should preserve shortcutSuffix field")
        }
        
        if case .pinClipboard(let suffix) = pinClipboardLeaf {
            XCTAssertEqual(suffix, " ⌘⇧V", "pinClipboard shortcut suffix should be preserved in structure")
        } else {
            XCTFail("pinClipboard should preserve shortcutSuffix field")
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
