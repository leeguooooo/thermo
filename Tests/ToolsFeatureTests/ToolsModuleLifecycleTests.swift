import ModuleKit
import NativeFeatureAPI
import SwiftUI
import ThermoKit
import XCTest
import ToolsControlAPI
@testable import ToolsFeature

@MainActor final class ToolsModuleLifecycleTests: XCTestCase {
    /// Records what a session asked of the tool, instead of touching the real models.
    final class Recorder {
        var started: [ShellTool] = [], stopped: [ShellTool] = [], drained: [ShellTool] = []
        var active: Set<ShellTool> = []
        var refuse: ShellTool?
        var runtime: ToolRuntime {
            .init(row: { _ in AnyView(Text("row")) }, panel: { _ in AnyView(Text("panel")) }, active: { self.active.contains($0) },
                  start: { self.started.append($0) }, stop: { tool in
                if tool == self.refuse { throw NativeFeatureBusy("busy") }
                self.stopped.append(tool); self.active.remove(tool)
                return { self.drained.append(tool) }
            })
        }
    }
    final class Switches { var off: Set<String> = [] }

    private func store(_ recorder: Recorder, _ switches: Switches) -> NativeFeatureStore {
        let runtime = recorder.runtime
        let definitions = ShellTool.allCases.map { ToolsFeature.definition($0, runtime: { runtime }) }
        return NativeFeatureStore(definitions: definitions, enabled: { !switches.off.contains($0) })
    }

    func testEveryToolIsABuiltinWithOneOptionsEntryAndDefaultsOn() throws {
        let ids = Set(ShellTool.allCases.map(\.manifest.id))
        XCTAssertEqual(ids, ["dev.thermo.focus", "dev.thermo.keep-awake", "dev.thermo.clean-screen", "dev.thermo.low-latency", "dev.thermo.battery-care"])
        XCTAssertEqual(ids, FeatureLaunchPolicy.toolIDs)
        for tool in ShellTool.allCases {
            XCTAssertTrue(BuiltinModuleManifests.all.contains { $0.id == tool.manifest.id })
            XCTAssertEqual(tool.manifest.entries.map(\.id), ["options"])
            XCTAssertEqual(tool.manifest.entries.first?.kind, .settingsItem)
            XCTAssertTrue(tool.manifest.enabledByDefault)
            XCTAssertTrue(tool.manifest.problems().isEmpty, "\(tool.manifest.problems())")
            XCTAssertEqual(ShellTool.owning(tool.manifest.id), tool)
        }
        // Registered in the order the settings page lists them, and accepted by the catalogue.
        let definitions = ToolsFeature.registrations(showPanel: { _ in }, installHelper: {})
        XCTAssertEqual(definitions.map(\.manifest.id), [ShellTool.cleanScreen, .keepAwake, .focus, .lowLatency, .batteryCare].map(\.manifest.id))
        XCTAssertNoThrow(try NativeFeatureCatalog(definitions: definitions))
        XCTAssertTrue(BuiltinModuleFootprints.footprint(ShellTool.cleanScreen.manifest.id).globalShortcuts)
    }

    func testSettingsKeysAreTheOnesUsedBeforeTheMigration() {
        XCTAssertEqual([FocusSettings.focusKey, FocusSettings.shortBreakKey, FocusSettings.longBreakKey, FocusSettings.longBreakEveryKey],
                       ["focus.focusMinutes", "focus.shortBreakMinutes", "focus.longBreakMinutes", "focus.longBreakEvery"])
        XCTAssertEqual(CleanScreenShortcutModel.preferenceKey, "dev.thermo.cleanScreen.shortcut")
        XCTAssertEqual(CleanScreenDuration.preferenceKey, "dev.thermo.cleanScreen.duration")
        XCTAssertEqual(BatteryCarePreferences.key, "batteryChargeLimit80Enabled")
    }

    func testStartingAndSwitchingOffEndsTheToolsWorkAndRemovesItsRow() async throws {
        let recorder = Recorder(), switches = Switches(), store = store(recorder, switches)
        for tool in ShellTool.allCases { store.startBackground(tool.manifest.id) }
        XCTAssertEqual(Set(recorder.started), Set(ShellTool.allCases))
        XCTAssertNotNil(store.inlineSettings(ShellTool.focus.options))
        XCTAssertNotNil(store.renderPreview(ShellTool.focus.options))
        recorder.active = [.focus]
        XCTAssertTrue(store.status(ShellTool.focus.manifest.id).sampling)

        let drain = try XCTUnwrap(try store.prepareStop(ShellTool.focus.manifest.id))
        switches.off.insert(ShellTool.focus.manifest.id)
        await drain.finish()
        XCTAssertEqual(recorder.stopped, [.focus]); XCTAssertEqual(recorder.drained, [.focus])
        XCTAssertNil(store.inlineSettings(ShellTool.focus.options))
        XCTAssertNil(store.renderPreview(ShellTool.focus.options))
        // Other tools stay where they were.
        XCTAssertNotNil(store.inlineSettings(ShellTool.keepAwake.options))
    }

    func testAToolThatCannotEndYetRefusesTheSwitch() throws {
        let recorder = Recorder(), switches = Switches(), store = store(recorder, switches)
        store.startBackground(ShellTool.batteryCare.manifest.id)
        recorder.refuse = .batteryCare
        XCTAssertThrowsError(try store.prepareStop(ShellTool.batteryCare.manifest.id))
        XCTAssertNotNil(store.inlineSettings(ShellTool.batteryCare.options))
    }

    func testSwitchedOffToolHasNoMenuIsNeverActiveAndRefusesOperations() async {
        let recorder = Recorder(), switches = Switches(), store = store(recorder, switches)
        let control = ToolsControl(enabled: { !switches.off.contains($0.manifest.id) })
        let access = ToolsAccess(store: store, control: control)
        XCTAssertFalse(access.menu(.focus).isEmpty)
        XCTAssertFalse(access.menu(.cleanScreen).isEmpty)
        switches.off = Set(ShellTool.allCases.map(\.manifest.id))
        for tool in ShellTool.allCases {
            XCTAssertTrue(access.menu(tool).isEmpty, tool.rawValue)
            XCTAssertFalse(access.isActive(tool), tool.rawValue)
        }
        XCTAssertEqual(access.keepAwakeMarker, "")
        for action in ["keep-awake.start", "screen.start", "awdl.on", "screen.shortcut"] {
            let reply = await access.handle(.init(action: action, arguments: action == "keep-awake.start" ? ["mode": "both", "seconds": "60"] : [:]))
            XCTAssertFalse(reply.succeeded, action)
            XCTAssertTrue(reply.issue?.contains("switched off") == true, action)
        }
        XCTAssertTrue(access.handles("keep-awake.status")); XCTAssertFalse(access.handles("login.on"))
    }
}

extension BatteryCareModelTests {
    @MainActor func testSwitchingTheFeatureOffRestoresNormalChargingAndKeepsThePreference() async {
        let rig = Rig(), pref = Preference(true); var exits = 0
        let model = BatteryCareModel(backend: rig.backend, preferences: pref.io, exit: { exits += 1 })
        model.restoreSavedPreference(); await settle(model); XCTAssertTrue(model.needsQuitRecovery)
        await model.releaseForSwitchOff()
        let stops = await rig.stops
        XCTAssertEqual(stops, 1); XCTAssertFalse(model.needsQuitRecovery); XCTAssertEqual(model.state?.policy, .off)
        XCTAssertTrue(pref.value, "the saved choice applies again when the feature is back on")
        XCTAssertEqual(exits, 0, "switching a feature off never quits Thermo")
        // Back on: the saved preference applies again.
        model.restoreSavedPreference(); await settle(model); XCTAssertTrue(model.needsQuitRecovery)
        model.change(.off); await settle(model)
    }
}

extension AWDLModelTests {
    @MainActor func testSwitchingTheFeatureOffRestoresAWDLWithoutQuitting() async {
        let rig = Rig(); var exits = 0
        let model = AWDLModel(backend: rig.backend, exit: { exits += 1 })
        model.open(); await settle(model); model.start(seconds: 60); await settle(model)
        XCTAssertTrue(model.needsQuitRecovery)
        await model.releaseForSwitchOff()
        XCTAssertFalse(model.needsQuitRecovery); XCTAssertEqual(model.state?.phase, .idle); XCTAssertEqual(exits, 0)
    }
}

