// Explicit integration check only. Never run by the builder or shipped App.
import AppKit
import ApplicationServices
import MenuBarCore

@MainActor enum MenuBarLiveManagerCheck {
    static func run() async -> Bool {
        let bundle = Bundle.main
        let root = bundle.bundleURL.deletingLastPathComponent()
        let output = root.appendingPathComponent("live-auto-collapse.json")
        guard bundle.bundleIdentifier?.hasPrefix("dev.thermo.menubarqa.real.") == true,
              bundle.object(forInfoDictionaryKey: "ThermoMenuBarQARole") as? String == "real-check",
              AXIsProcessTrusted(),
              let hidden = bundle.object(forInfoDictionaryKey: "ThermoMenuBarRealHiddenBundle") as? String,
              let always = bundle.object(forInfoDictionaryKey: "ThermoMenuBarRealAlwaysBundle") as? String,
              hidden != always, MenuBarSections.isAssignable(hidden), MenuBarSections.isAssignable(always),
              !FileManager.default.fileExists(atPath: output.path),
              [hidden, always, "dev.thermo.app"].allSatisfy({ id in
                  NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { !$0.isTerminated }
              }) else {
            print("Live check refused: needs isolated Real Check, existing Accessibility trust, two running targets and a new output file.")
            return false
        }
        let suite = "MenuBarLiveManagerQA." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let model = MenuBarManager(defaults: defaults)
        guard model.available else { defaults.removePersistentDomain(forName: suite); return false }
        var events: [[String: Any]] = []
        var watchdogFired = false
        let began = ProcessInfo.processInfo.systemUptime
        func record(_ phase: String, error: String? = nil) {
            var event: [String: Any] = ["phase": phase, "time": Date().timeIntervalSince1970,
                "elapsedSeconds": ProcessInfo.processInfo.systemUptime - began,
                "state": String(describing: model.state), "reveal": String(describing: model.reveal),
                "enabled": model.enabled, "autoCollapseScheduled": model.autoCollapsePending]
            if let error { event["error"] = error }
            events.append(event)
            let report: [String: Any] = ["phase": phase, "events": events, "hiddenBundle": hidden,
                "alwaysHiddenBundle": always, "watchdogSeconds": 40, "watchdogFired": watchdogFired,
                "systemAuthorization": true, "productionPreferencesChanged": false,
                "pixelAcceptance": "not automatically asserted"]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output, options: .atomic)
            }
        }
        let watchdog = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 40_000_000_000) } catch { return }
            watchdogFired = true
            model.shutdown()
            record("watchdog-restored")
        }
        defer {
            watchdog.cancel()
            model.shutdown()
            record("finished")
            defaults.removePersistentDomain(forName: suite)
        }
        func failure(_ message: String) -> NSError {
            NSError(domain: "MenuBarLiveManagerCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        func waitForApplied() async throws {
            let until = ProcessInfo.processInfo.systemUptime + 4.5
            while model.state == .applying && ProcessInfo.processInfo.systemUptime < until {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            guard model.enabled, model.state == .applied else {
                throw failure("Visibility request was not applied: \(model.state)")
            }
        }
        do {
            defaults.set(true, forKey: MenuBarManager.enabledKey)
            model.start()
            guard model.enabled else { throw failure("Existing system authorization did not enable the model") }
            model.assign(hidden, to: .hidden)
            model.assign(always, to: .alwaysHidden)
            let assignments = defaults.data(forKey: MenuBarSectionStore.key)
            model.setAutoCollapseDelay(.tenSeconds)
            record("baseline")
            try await Task.sleep(nanoseconds: 3_000_000_000)
            model.setReveal(.hidden)
            try await waitForApplied()
            guard model.autoCollapsePending else { throw failure("Auto-collapse was not scheduled") }
            record("hidden-revealed")
            let until = ProcessInfo.processInfo.systemUptime + 15
            while model.reveal == .hidden && ProcessInfo.processInfo.systemUptime < until {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard model.reveal == .collapsed else { throw failure("Auto-collapse did not expire") }
            try await waitForApplied()
            guard !model.autoCollapsePending else { throw failure("Expired timer remained scheduled") }
            record("auto-collapsed")
            try await Task.sleep(nanoseconds: 8_000_000_000)
            model.restoreAll()
            guard model.state == .visible, !model.autoCollapsePending else { throw failure("Restore failed") }
            record("restored")
            try await Task.sleep(nanoseconds: 10_500_000_000)
            guard !watchdogFired, model.reveal == .all, model.state == .visible,
                  !model.autoCollapsePending, defaults.data(forKey: MenuBarSectionStore.key) == assignments else {
                throw failure("Restoration did not remain expanded or assignments changed")
            }
            record("protocol-passed")
            return true
        } catch {
            model.restoreAll()
            record("failed-restored", error: error.localizedDescription)
            return false
        }
    }
}
