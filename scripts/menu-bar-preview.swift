// Compiled only by verify-menu-bar.py, using the actual manager and panel sources.
// The delegate substitutes only Thermo's unrelated application lifecycle.
import AppKit
import ApplicationServices
import CMenuBar
import MenuBarCore
import ThermoL10n

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem?
    private var session: TMMenuBarSession?
    private var checks: [String: Any] = [:]
    private var finished = false
    private var visualCheck: MenuBarVisualCheck?
    private var dragCheck: MenuBarManagerPanel?
    private var dragModel: MenuBarManager?
    func closeMenuPanel() {}
    func applicationDidFinishLaunching(_ notification: Notification) {
        if menuBarFixtureMode {
            guard Bundle.main.bundleIdentifier?.hasPrefix("org.example.mbfx.") == true else { exit(2) }
            item = NSStatusBar.system.statusItem(withLength: 48)
            let label = Bundle.main.object(forInfoDictionaryKey: "ThermoMenuBarFixtureLabel") as? String ?? "MBFX"
            let previousImagePosition = (item?.button?.imagePosition.rawValue).map { Int($0) } ?? -1
            let marker = NSImage(size: NSSize(width: 44, height: 18), flipped: false) { rect in
                (label as NSString).draw(in: rect.insetBy(dx: 1, dy: 1), withAttributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold), .foregroundColor: NSColor.black
                ])
                return true
            }
            marker.isTemplate = true
            item?.button?.image = marker
            item?.button?.imagePosition = .imageOnly
            item?.button?.setAccessibilityLabel(label)
            let rendering: [String: Any] = ["label": label, "defaultImagePosition": previousImagePosition,
                                            "configuredImagePosition": (item?.button?.imagePosition.rawValue).map { Int($0) } ?? -1,
                                            "statusLength": item?.length ?? 0, "usesTemplateRasterMarker": true]
            if let data = try? JSONSerialization.data(withJSONObject: rendering, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(label + "-rendering.json"), options: .atomic)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [self] in
                if let item { NSStatusBar.system.removeStatusItem(item) }
                NSApp.terminate(nil)
            }
        }
        else if ["visual-check", "real-check"].contains(Bundle.main.object(forInfoDictionaryKey: "ThermoMenuBarQARole") as? String ?? "") {
            visualCheck = MenuBarVisualCheck(realApps: Bundle.main.object(forInfoDictionaryKey: "ThermoMenuBarQARole") as? String == "real-check"); visualCheck?.show()
        }
        else if Bundle.main.object(forInfoDictionaryKey: "ThermoMenuBarQARole") as? String == "drag-check" {
            let root = Bundle.main.bundleURL.deletingLastPathComponent()
            let names = ["Thermo Menu Bar Visible Fixture", "Thermo Menu Bar Fixture", "Thermo Menu Bar Always Fixture"]
            let apps = names.compactMap { name -> ManagedMenuBarApp? in
                guard let bundle = Bundle(url: root.appendingPathComponent(name + ".app"))?.bundleIdentifier,
                      bundle.hasPrefix("org.example.mbfx.") else { return nil }
                return ManagedMenuBarApp(id: bundle, name: name.replacingOccurrences(of: "Thermo Menu Bar ", with: ""))
            }
            let model = MenuBarManager(initialApps: apps)
            dragModel = model
            dragCheck = MenuBarManagerPanel(model: model)
            dragCheck?.window?.title = "拖拽分组验收（测试应用）"
            dragCheck?.show()
        }
        else if CommandLine.arguments.contains("--self-test") { runSelfTest() }
        else {
            let main = NSMenu()
            let application = NSMenuItem()
            let submenu = NSMenu()
            submenu.delegate = self
            for (title, selector, key) in [(tr("Manage menu bar…"), #selector(openManager), "m")] {
                let entry = submenu.addItem(withTitle: title, action: selector, keyEquivalent: key)
                entry.target = self
            }
            submenu.addItem(.separator())
            submenu.addItem(withTitle: "Quit Preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            application.submenu = submenu; main.addItem(application); NSApp.mainMenu = main
            openManager()
        }
    }
    @objc private func openManager() { MenuBarManagerPanel.shared.show() }
    func menuNeedsUpdate(_ menu: NSMenu) {
        // Keep the first Manage entry and the Quit separator/entry. Rebuild the
        // same controls shipped in Thermo whenever this preview menu opens.
        while menu.items.count > 3 { menu.removeItem(at: 1) }
        for control in MenuBarQuickControls.items(model: .shared).reversed() {
            menu.insertItem(control, at: 1)
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        visualCheck?.restore()
        if let dragModel {
            let result: [String: Any] = ["assignments": dragModel.sections.assignments.mapValues(\.rawValue),
                                       "nativeHidingEnabled": dragModel.enabled,
                                       "bundle": Bundle.main.bundleIdentifier ?? ""]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("drag-check-result.json"), options: .atomic)
            }
            dragModel.shutdown()
        }
        if !menuBarFixtureMode {
            MenuBarManager.shared.shutdown()
        }
        try? session?.invalidate()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !CommandLine.arguments.contains("--self-test") && !menuBarFixtureMode
    }

    private func runSelfTest() {
        guard let own = Bundle.main.bundleIdentifier, own.hasPrefix("dev.thermo.menubarqa."),
              AXIsProcessTrusted(), TMMenuBarSession.isAvailable() else {
            finish(error: "Self-test needs its isolated app bundle, Accessibility and macOS 27 interface.")
            return
        }
        guard let index = CommandLine.arguments.firstIndex(of: "--self-test"), index + 1 < CommandLine.arguments.count else {
            finish(error: "Pass the separately running disposable fixture bundle ID."); return
        }
        let target = CommandLine.arguments[index + 1]
        guard target.hasPrefix("org.example.mbfx."),
              let fixture = NSRunningApplication.runningApplications(withBundleIdentifier: target).first,
              fixture.bundleURL?.lastPathComponent == "Thermo Menu Bar Fixture.app",
              fixture.bundleURL?.deletingLastPathComponent() == Bundle.main.bundleURL.deletingLastPathComponent() else {
            finish(error: "Target is not the running fixture next to this isolated preview."); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [self] in
            let before = Set(MenuBarAppDiscovery.snapshot().map(\.id))
            checks["fixtureDiscoveredBefore"] = before.contains(target)
            guard before.contains(target) else { finish(error: "Disposable item was not discovered; no hiding attempted."); return }
            let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            do {
                session = try TMMenuBarSession.make(allowedBundles: running.union([own]).subtracting([target]).sorted())
                // A watchdog requests restoration even if activation never calls back.
                let observe = CommandLine.arguments.contains("--observe")
                DispatchQueue.main.asyncAfter(deadline: .now() + (observe ? 20 : 5)) { [self] in
                    if !finished { finish(error: "Native callback or visibility check timed out.") }
                }
                session?.activate { [self] error in
                    let message = error?.localizedDescription
                    Task { @MainActor [self] in
                        guard !self.finished else { try? self.session?.invalidate(); return }
                        if let message { self.finish(error: message); return }
                        self.checks["activationCallbackSucceeded"] = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [self] in
                            let during = Set(MenuBarAppDiscovery.snapshot().map(\.id))
                            checks["fixtureAbsentWhileHidden"] = !during.contains(target)
                            checks["otherDiscoveredBundlesLost"] = before.subtracting(during).subtracting([target]).sorted()
                            if observe { fputs("Native session active; 10-second observation window.\n", stderr); fflush(stderr) }
                            DispatchQueue.main.asyncAfter(deadline: .now() + (observe ? 10 : 0)) { [self] in
                              do { try session?.invalidate(); checks["restoreRequested"] = true }
                              catch { finish(error: error.localizedDescription); return }
                              DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [self] in
                                let after = Set(MenuBarAppDiscovery.snapshot().map(\.id))
                                checks["fixtureRestored"] = after.contains(target)
                                checks["otherDiscoveredBundlesMissingAfterRestore"] = before.subtracting(after).subtracting([target]).sorted()
                                let lost = checks["otherDiscoveredBundlesLost"] as? [String] ?? []
                                let missing = checks["otherDiscoveredBundlesMissingAfterRestore"] as? [String] ?? []
                                let passed = !during.contains(target) && after.contains(target) && lost.isEmpty && missing.isEmpty
                                finish(error: passed ? nil : "AX visibility or collateral bundle check failed.")
                              }
                            }
                        }
                    }
                }
            } catch { finish(error: error.localizedDescription) }
        }
    }

    private func finish(error: String?) {
        guard !finished else { return }
        finished = true
        do { try session?.invalidate() }
        catch { checks["finalRestorationError"] = error.localizedDescription }
        if let item { NSStatusBar.system.removeStatusItem(item) }
        checks["scope"] = "Separate disposable fixture bundle; AX observations only, no pixel or system-module acceptance."
        checks["error"] = error ?? NSNull()
        checks["passed"] = error == nil && checks["finalRestorationError"] == nil
        let data = try! JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        fflush(stdout)
        exit(checks["passed"] as? Bool == true ? 0 : 1)
    }
}

let menuBarFixtureMode = CommandLine.arguments.contains("--fixture") ||
    Bundle.main.bundleIdentifier?.hasPrefix("org.example.mbfx.") == true
let application = NSApplication.shared
if CommandLine.arguments.contains("--check-quick-controls") {
    // Exercise the actual native menu actions with absent identities. There is
    // no visibility assertion to apply and no installed preference is touched.
    let passed = MainActor.assumeIsolated { () -> Bool in
        let suite = "MenuBarQuickControlsQA." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = MenuBarManager(defaults: defaults)
        defer { model.shutdown() }
        guard MenuBarQuickControls.items(model: model).isEmpty else { return false }
        let absent = "org.example.menubar-absent." + UUID().uuidString
        model.assign(absent, to: .hidden)
        let original = defaults.data(forKey: MenuBarSectionStore.key)
        defaults.set(true, forKey: MenuBarManager.enabledKey)
        model.start()
        guard model.enabled else { return false }
        @MainActor func invoke(_ index: Int) -> Bool {
            let menu = NSMenu(); menu.autoenablesItems = false
            for entry in MenuBarQuickControls.items(model: model) { menu.addItem(entry) }
            guard menu.items.indices.contains(index) else { return false }
            menu.performActionForItem(at: index)
            return true
        }
        guard invoke(0), model.reveal == .collapsed,
              invoke(0), model.reveal == .hidden,
              invoke(1), model.reveal == .all,
              model.enabled, model.state == .visible,
              defaults.data(forKey: MenuBarSectionStore.key) == original else { return false }
        model.setEnabled(false)
        return MenuBarQuickControls.items(model: model).isEmpty
    }
    print("{\"quickControlsPassed\":\(passed),\"nativeVisibilityAsserted\":false}")
    exit(passed ? 0 : 1)
}
if CommandLine.arguments.contains("--probe") {
    let result: [String: Any] = ["available": TMMenuBarSession.isAvailable(), "accessibilityTrusted": AXIsProcessTrusted(),
                               "os": ProcessInfo.processInfo.operatingSystemVersionString,
                               "bundle": Bundle.main.bundleIdentifier ?? "unbundled"]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self)); exit(0)
}
L10n.apply(preference: "zh-Hans")
application.setActivationPolicy(CommandLine.arguments.contains("--self-test") || menuBarFixtureMode ? .accessory : .regular)
let delegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate
withExtendedLifetime(delegate) { application.run() }
