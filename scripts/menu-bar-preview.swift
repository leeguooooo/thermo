// Compiled only by verify-menu-bar.py, using the actual manager and panel sources.
// The delegate substitutes only Thermo's unrelated application lifecycle.
import AppKit
import ApplicationServices
import CMenuBar
import ThermoL10n

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem?
    private var session: TMMenuBarSession?
    private var checks: [String: Any] = [:]
    private var finished = false
    func closeMenuPanel() {}
    func applicationDidFinishLaunching(_ notification: Notification) {
        if menuBarFixtureMode {
            guard Bundle.main.bundleIdentifier?.hasPrefix("org.example.thermo-menubar-fixture.") == true else { exit(2) }
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item?.button?.title = "MBFX"
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [self] in
                if let item { NSStatusBar.system.removeStatusItem(item) }
                NSApp.terminate(nil)
            }
        }
        else if CommandLine.arguments.contains("--self-test") { runSelfTest() }
        else {
            let main = NSMenu()
            let application = NSMenuItem()
            let submenu = NSMenu()
            for (title, selector, key) in [(tr("Manage menu bar…"), #selector(openManager), "m"), (tr("Extensions…"), #selector(openExtensions), ",")] {
                let entry = submenu.addItem(withTitle: title, action: selector, keyEquivalent: key)
                entry.target = self
            }
            submenu.addItem(.separator())
            submenu.addItem(withTitle: "Quit Preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            application.submenu = submenu; main.addItem(application); NSApp.mainMenu = main
            if CommandLine.arguments.contains("--extensions") { openExtensions() } else { openManager() }
        }
    }
    @objc private func openManager() { ToolExtensionHost.shared.open("builtin.menubar") }
    @objc private func openExtensions() { ToolExtensionPanel.shared.show() }
    func applicationWillTerminate(_ notification: Notification) {
        ToolExtensionHost.shared.shutdown()
        MenuBarManager.shared.shutdown()
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
        guard target.hasPrefix("org.example.thermo-menubar-fixture."),
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
                session?.activate { error in
                    let message = error?.localizedDescription
                    Task { @MainActor [self] in
                        guard !finished else { try? session?.invalidate(); return }
                        if let message { finish(error: message); return }
                        checks["activationCallbackSucceeded"] = true
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
    Bundle.main.bundleIdentifier?.hasPrefix("org.example.thermo-menubar-fixture.") == true
let application = NSApplication.shared
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
