import AppKit
import AgentCore
import CaptureCore
import CaptureScriptCore
import ModuleHost
import ModuleKit
import XCTest
@testable import ThermoApp

@MainActor final class CaptureModuleTests: XCTestCase {
    final class Flag { var on = false; var accessRequests = 0 }
    enum Failure: Error { case release }
    final class Lease: CleanScreenHotkeyLease {
        var released = false; var fails = false
        func release() throws { if fails { throw Failure.release }; released = true }
    }
    final class Backend: CleanScreenHotkeyBackend {
        var leases: [Lease] = []; var events: [(Bool) -> Void] = []
        func register(_ key: CleanScreenKeyBinding, event: @escaping (Bool) -> Void) throws -> CleanScreenHotkeyLease {
            let lease = Lease(); leases.append(lease); events.append(event); return lease
        }
    }
    func workspace(_ flag: Flag, root: URL, backend: Backend) -> CaptureWorkspace {
        let shortcuts = CaptureShortcutModel(backend: backend, read: { nil }, write: { _ in }, pinFocused: { false }, execute: { _ in })
        return CaptureWorkspace(pinSession: CapturePinSession(store: .init(root: root)),
            screenCaptureAccess: { flag.accessRequests += 1; return false },
            featureEnabled: { flag.on }, shortcuts: shortcuts)
    }
    func testManifestUsesPrewarmAndHasRegisteredMenuAndSettings() {
        XCTAssertEqual(CaptureModule.manifest.launch, .prewarm)
        XCTAssertTrue(CaptureModule.manifest.enabledByDefault)
        XCTAssertTrue(CaptureModule.manifest.problems().isEmpty)
        XCTAssertTrue(CaptureModule.manifest.entries.allSatisfy(CaptureModule.supports))
        XCTAssertEqual(CaptureModule.manifest.entries.filter { $0.kind == .settingsItem }.count, 2)
        XCTAssertTrue(BuiltinModules.problems.isEmpty)
    }
    func testColdOffNeverRegistersHotkeysOrAsksForScreenAccess() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let flag = Flag(), backend = Backend(), model = workspace(flag, root: root, backend: backend)
        defer { model.shutdown() }
        model.activate(); model.capture(); model.captureScrolling(); model.recordScreen(); model.recordScreen(draftsOnly: true)
        model.showSavingSettings(); model.showActionSettings(); model.pinClipboard(); model.showPinLibrary()
        XCTAssertTrue(backend.leases.isEmpty)
        XCTAssertEqual(flag.accessRequests, 0)
        XCTAssertFalse(model.capturing || model.recordingActive)
        XCTAssertThrowsError(try model.perform(.screenshot))
        do { _ = try await model.executeScript("return 1;"); XCTFail("started worker while off") } catch {}
        let host = CaptureCLIHost(workspace: model)
        for action in ["capture.run", "capture.action"] {
            let response = await host.handle(.init(action: action, arguments: ["source": "return 1;"], dryRun: true))
            XCTAssertFalse(response.succeeded)
            XCTAssertTrue(response.issue?.contains("switched off") == true)
        }
        XCTAssertFalse(model.scriptRunning)
    }
    func testEnablePrewarmsOnceStopReleasesAndReenableRegistersAgain() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let flag = Flag(), backend = Backend(), model = workspace(flag, root: root, backend: backend)
        defer { model.shutdown() }
        flag.on = true; model.activate()
        let count = backend.leases.count
        XCTAssertGreaterThan(count, 0)
        model.activate(); XCTAssertEqual(backend.leases.count, count)
        XCTAssertEqual(flag.accessRequests, 0, "prewarming never asks for screen recording")
        try model.stopFeature(); flag.on = false
        XCTAssertTrue(backend.leases.allSatisfy { $0.released })
        flag.on = true; model.activate()
        XCTAssertEqual(backend.leases.count, count * 2)
    }
    func testBusyOrUnconfirmedShortcutReleaseRefusesStop() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let flag = Flag(), backend = Backend(), model = workspace(flag, root: root, backend: backend)
        defer { model.shutdown() }
        flag.on = true; model.activate(); model.scriptRunning = true
        XCTAssertThrowsError(try model.stopFeature())
        XCTAssertFalse(backend.leases.contains { $0.released })
        model.scriptRunning = false
        let lease = try XCTUnwrap(backend.leases.first); lease.fails = true
        XCTAssertThrowsError(try model.stopFeature())
        XCTAssertTrue(model.shortcuts.uncertain)
        let count = backend.leases.count; model.activate()
        XCTAssertEqual(backend.leases.count, count, "never reregister over an uncertain lease")
        lease.fails = false; try model.stopFeature()
        XCTAssertTrue(lease.released)
    }
    func testModuleCenterStartsOnlyEnabledBuiltinsAndStartsOnReenable() {
        let name = "thermo-capture-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: ModuleCenter.key(CaptureModule.manifest.id))
        var starts: [String] = []
        let center = ModuleCenter(defaults: defaults, prepareBuiltinStop: { _ in nil }, startBuiltin: { starts.append($0) })
        center.start(); center.start()
        XCTAssertFalse(starts.contains(CaptureModule.manifest.id))
        center.setEnabled(CaptureModule.manifest.id, true)
        XCTAssertEqual(starts.filter { $0 == CaptureModule.manifest.id }.count, 1)
        center.setEnabled(CaptureModule.manifest.id, false)
        XCTAssertFalse(center.isOn(CaptureModule.manifest.id))
    }
    func testOffscreenStartupDoesNotWarmNativeFeatures() {
        let name = "thermo-capture-offscreen-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var starts: [String] = []
        let center = ModuleCenter(defaults: defaults, startBuiltin: { starts.append($0) })
        center.start(prewarmBuiltins: false)
        XCTAssertTrue(starts.isEmpty)
        XCTAssertTrue(center.isOn(CaptureModule.manifest.id))
    }
    func testDisablingCaptureRemovesBothMenuGroups() {
        let context = StatusMenuLayout.RuntimeContext(captureEnabled: false, hasBattery: true, keepAwakeActive: false,
            focusTimerActive: false, configuredCaptureEntriesAppear: true, menuBarQuickControlsAppear: false,
            updatesCanCheck: true, moreToolsActiveStates: .init(cleanScreenActive: false, lowLatencyActive: false, batteryProtectionActive: false))
        let layout = StatusMenuLayout.make(context: context, captureShortcutSuffix: "", pinShortcutSuffix: "", configuredCaptureEntries: ["custom"])
        let titles = layout.productItems.compactMap { item -> String? in if case let .menuGroup(group) = item { return group.title }; return nil }
        XCTAssertFalse(titles.contains("Capture & record") || titles.contains("Clipboard & pins"))
        XCTAssertFalse(layout.productItems.isEmpty)
    }
}
