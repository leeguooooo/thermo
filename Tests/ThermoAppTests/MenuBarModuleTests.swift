import XCTest
import ModuleKit
import MenuBarCore
@testable import ThermoApp

@MainActor final class MenuBarModuleTests: XCTestCase {
    final class Flag { var on = true; var permissionReads = 0 }
    final class Session: MenuBarVisibilitySession {
        var failure: String?; var restored = 0
        func activate(completion: @escaping @MainActor (String?) -> Void) { completion(nil) }
        func invalidate() -> String? { restored += 1; return failure }
    }
    func testManifestAndRegistryCoverMenuAndSettings() {
        XCTAssertEqual(MenuBarModule.manifest.launch, .always)
        XCTAssertTrue(MenuBarModule.manifest.enabledByDefault)
        XCTAssertTrue(MenuBarModule.manifest.entries.allSatisfy(MenuBarModule.supports))
        XCTAssertTrue(BuiltinModules.problems.isEmpty)
        XCTAssertEqual(Set(BuiltinModules.all.map(\.id)),Set(BuiltinModuleManifests.all.map(\.id)))
    }
    func testClosedFeatureDoesNotAskForPermissionsOrRegisterShortcuts() {
        let suite="thermo-menubar-off-"+UUID().uuidString, flag=Flag()
        let defaults=UserDefaults(suiteName:suite)!,backend=MenuBarShortcutTests.Backend()
        defer { defaults.removePersistentDomain(forName:suite) }
        defaults.set(true,forKey:MenuBarManager.enabledKey)
        defaults.set(true,forKey:MenuBarShortcuts.preferenceKey)
        flag.on=false
        let model=MenuBarManager(defaults:defaults,accessibilityTrusted:{flag.permissionReads += 1;return true},shortcutBackend:backend,featureEnabled:{flag.on})
        defer { model.shutdown() }
        model.start();model.setEnabled(true);model.setPanelOpen(true);model.setReveal(.collapsed)
        XCTAssertFalse(model.enabled || model.shortcuts.active || model.loading)
        XCTAssertEqual(flag.permissionReads,0)
        XCTAssertTrue(backend.leases.isEmpty)
        XCTAssertFalse(model.canEdit)
    }
    func testStoppingRestoresVisibilityAndKeepsSavedPreferencesForReenable() throws {
        let suite="thermo-menubar-stop-"+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!,backend=MenuBarShortcutTests.Backend(),session=Session()
        defer { defaults.removePersistentDomain(forName:suite) }
        defaults.set(true,forKey:MenuBarManager.enabledKey)
        defaults.set(true,forKey:MenuBarShortcuts.preferenceKey)
        let controller=MenuBarSessionController {_ in session}
        let model=MenuBarManager(defaults:defaults,accessibilityTrusted:{true},shortcutBackend:backend,controller:controller)
        defer { model.shutdown() }
        guard model.available else {throw XCTSkip("Native menu management requires macOS 27")}
        model.start();controller.apply(.init(allowedBundles:["com.example.fixture"]))
        XCTAssertEqual(controller.state,.applied)
        try model.stopFeature()
        XCTAssertEqual(controller.state,.visible)
        XCTAssertGreaterThan(session.restored,0)
        XCTAssertFalse(model.enabled || model.shortcuts.active)
        XCTAssertTrue(backend.leases.allSatisfy {$0.releases > 0})
        XCTAssertTrue(defaults.bool(forKey:MenuBarManager.enabledKey),"module switch preserves the user's management configuration")
        model.start();XCTAssertTrue(model.enabled && model.shortcuts.active)
    }
    func testUnconfirmedRestorationRefusesStopAndKeepsRecoveryAvailable() throws {
        let suite="thermo-menubar-recovery-"+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!,backend=MenuBarShortcutTests.Backend(),session=Session()
        defer { defaults.removePersistentDomain(forName:suite) }
        defaults.set(true,forKey:MenuBarManager.enabledKey)
        defaults.set(true,forKey:MenuBarShortcuts.preferenceKey)
        let controller=MenuBarSessionController {_ in session}
        let model=MenuBarManager(defaults:defaults,accessibilityTrusted:{true},shortcutBackend:backend,controller:controller)
        defer { session.failure=nil;model.shutdown() }
        guard model.available else {throw XCTSkip("Native menu management requires macOS 27")}
        model.start();controller.apply(.init(allowedBundles:["com.example.fixture"]))
        session.failure="fixture restoration not confirmed"
        XCTAssertThrowsError(try model.stopFeature())
        XCTAssertEqual(model.state,.failed("fixture restoration not confirmed"))
        XCTAssertTrue(model.shortcuts.active,"do not retire recovery controls while system visibility is uncertain")
        session.failure=nil;try model.stopFeature()
        XCTAssertEqual(model.state,.visible)
    }
    func testUnreleasedShortcutRefusesStopAfterRestoration() throws {
        let suite="thermo-menubar-lease-"+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!,backend=MenuBarShortcutTests.Backend()
        defer { defaults.removePersistentDomain(forName:suite) }
        defaults.set(true,forKey:MenuBarManager.enabledKey)
        defaults.set(true,forKey:MenuBarShortcuts.preferenceKey)
        let model=MenuBarManager(defaults:defaults,accessibilityTrusted:{true},shortcutBackend:backend)
        defer { for lease in backend.leases {lease.fails=false};model.shutdown() }
        guard model.available else {throw XCTSkip("Native menu management requires macOS 27")}
        model.start();try XCTUnwrap(backend.leases.first).fails=true
        XCTAssertThrowsError(try model.stopFeature())
        XCTAssertEqual(model.state,.visible)
        XCTAssertTrue(model.shortcuts.uncertain)
    }
    func testModuleOffHidesManagementEntryButKeepsEmergencyRecovery() {
        let context=StatusMenuLayout.RuntimeContext(menuBarEnabled:false,hasBattery:true,keepAwakeActive:false,focusTimerActive:false,
            configuredCaptureEntriesAppear:false,menuBarQuickControlsAppear:true,updatesCanCheck:true,
            moreToolsActiveStates:.init(cleanScreenActive:false,lowLatencyActive:false,batteryProtectionActive:false))
        let layout=StatusMenuLayout.make(context:context,captureShortcutSuffix:"",pinShortcutSuffix:"",configuredCaptureEntries:[])
        XCTAssertFalse(layout.productItems.contains {if case .manageMenuBar=$0{return true};return false})
        XCTAssertFalse(layout.retainedExtras.quickControls.isEmpty)
    }
}
