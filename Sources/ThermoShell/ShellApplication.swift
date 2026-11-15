import AppKit
import Foundation
import ModuleKit
import SwiftUI
import SystemServicesAPI
import ThermoKit
import ThermoL10n

@MainActor private(set) var featureLaunchState:FeatureLaunchPolicy.State?

@MainActor package enum ShellApplication {
    package static func install(factory:any ShellFeatureFactory) {ShellFeatureInstallation.shared.install(factory:factory)}
    package static func run(factory:any ShellFeatureFactory) {
        featureLaunchState = {
            guard FeatureLaunchPolicy.allowsInteractiveSelection(arguments: CommandLine.arguments,
                                                                environment: ProcessInfo.processInfo.environment),
                  NSClassFromString("XCTestCase") == nil else { return nil }
            return FeatureLaunchPolicy.assess(defaults: .standard, domain: ModulePreferences.appDomain,
                                             home: URL(fileURLWithPath: NSHomeDirectory()))
        }()
        install(factory:factory)
        launchApplication()
    }
}

@MainActor private func launchApplication() {
    // Capture upgrade evidence before SingleInstance creates Application Support/Thermo/app.lock.
    // Only ordinary launches and bare --main/--search consume onboarding; QA modes never do.
    L10n.apply(preference: UserDefaults.standard.string(forKey: L10n.defaultsKey))
    // Freeze launch metadata before an updater can replace the bundle on disk.
    _ = AppInfo.buildMetadata
    MainActor.assumeIsolated { _ = AppInstallationMonitor.shared }
    let app = NSApplication.shared
    // `--dump-status-menu`: print the menu bar item's menu (titles, separators, submenus) and quit,
    // so its grouping and wording can be reviewed without opening it on screen.
    if CommandLine.arguments.contains("--dump-status-menu") {
        MainActor.assumeIsolated {
            func dump(_ menu: NSMenu, _ depth: Int) {
                for item in menu.items {
                    print(String(repeating: "    ", count: depth) + (item.isSeparatorItem ? "────" : item.title))
                    if let sub = item.submenu { dump(sub, depth + 1) }
                }
            }
            dump(StatusMenu.shared.make(battery: true), 0)
        }
        exit(0)
    }
    // `--show-status-menu` / `--show-panel`: put the menu bar item's menu, or the panel in a plain window,
    // on screen for a few seconds and quit, so they can be checked visually while another Thermo runs.
    if CommandLine.arguments.contains("--show-status-menu") || CommandLine.arguments.contains("--show-panel") {
        app.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            Settings.register()
            let center = NSScreen.main.map { NSPoint(x: $0.frame.midX - 160, y: $0.frame.midY + 240) } ?? .zero
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                NSApp.activate(ignoringOtherApps: true)
                if CommandLine.arguments.contains("--show-status-menu") {
                    let menu = StatusMenu.shared.make(battery: true)
                    let menuSeconds: TimeInterval = {
                        let args = CommandLine.arguments
                        guard let i = args.firstIndex(of: "--menu-seconds"), i + 1 < args.count,
                              let value = Double(args[i + 1]), value.isFinite, (2...120).contains(value) else { return 6 }
                        return value
                    }()
                    let close = Timer(timeInterval: menuSeconds, repeats: false) { _ in menu.cancelTracking() }
                    RunLoop.main.add(close, forMode: .common)
                    print("shown"); fflush(stdout)
                    // Where the menu bar item would drop it: just under the menu bar.
                    let top = NSScreen.main.map { NSPoint(x: $0.frame.maxX - 560, y: $0.visibleFrame.maxY) } ?? center
                    menu.popUp(positioning: nil, at: top, in: nil)
                    exit(0)
                }
                let monitor = ShellState.shared.system
                ShellState.shared.nativeFeatures.start(BuiltinModuleManifests.performance.id)
                ShellState.shared.nativeFeatures.setMenuPanelVisible(true)
                monitor.popoverOpen = true
                let w = NSWindow(contentRect: NSRect(x: center.x, y: center.y - 560, width: 360, height: 600),
                                 styleMask: [.titled], backing: .buffered, defer: false)
                w.title = "Thermo panel check"
                w.contentView = NSHostingView(rootView: PopoverView(monitor: monitor))
                w.makeKeyAndOrderFront(nil)
                print("shown"); fflush(stdout)
                DispatchQueue.main.asyncAfter(deadline: .now() + 25) { exit(0) }
            }
        }
        app.run()
    }
    // Snapshot/render jobs do not present interactive windows or create Dock items.
    if !CommandLine.arguments.contains("--offscreen"), !CommandLine.arguments.contains("--render-preview"), !CommandLine.arguments.contains("--verify-lifecycle") {
        do {
            guard try MainActor.assumeIsolated({ try SingleInstance.claim() }) else { exit(0) }
        } catch {
            fputs("Thermo cannot acquire its instance lock: \(error)\n", stderr)
            exit(1)
        }
    }
    // The lock winner alone writes migration state, before AppDelegate/model initializers run.
    if let featureLaunchState {
        FeatureLaunchPolicy.install(featureLaunchState, in: .standard, persist: true)
    }
    if CommandLine.arguments.contains("--verify-lifecycle") {
        do {
            let options = try MainActor.assumeIsolated { try WindowLifecycleCheck.Options(arguments: CommandLine.arguments) }
            app.setActivationPolicy(.accessory)
            let lifecycleDelegate = MainActor.assumeIsolated { MainOnlyDelegate() }
            app.delegate = lifecycleDelegate
            DispatchQueue.main.async {
                Task { @MainActor in
                    do {
                        let report = try await WindowLifecycleCheck.run(options)
                        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                        try encoder.encode(report).write(to: URL(fileURLWithPath: options.output), options: .atomic)
                        exit(report.functionalChecksPassed ? 0 : 2)
                    } catch { fputs("Lifecycle verification failed: \(error)\n", stderr); exit(1) }
                }
            }
            withExtendedLifetime(lifecycleDelegate) { app.run() }
        } catch { fputs("Lifecycle verification failed: \(error)\n", stderr); exit(1) }
    }
    if let i = CommandLine.arguments.firstIndex(of: "--render-preview"), i + 1 < CommandLine.arguments.count {
        app.setActivationPolicy(.prohibited)
        MainActor.assumeIsolated { renderPreviews(to: CommandLine.arguments[i + 1]) }
        app.run()
    }
    if ["--main", "--disk", "--agents", "--chrome-pages"].contains(where: CommandLine.arguments.contains) {
        let mainOnlyDelegate = MainActor.assumeIsolated { MainOnlyDelegate() }
        MainActor.assumeIsolated {
            mainOnlyDelegate.deferInstallationMonitor = featureLaunchState?.needsSelection == true
        }
        app.delegate = mainOnlyDelegate
        // `--offscreen`: no Dock icon, no window on the user's screen.
        app.setActivationPolicy(CommandLine.arguments.contains("--offscreen") ? .accessory : .regular)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                mainOnlyDelegate.featureLaunch.launch(needsSelection: featureLaunchState?.needsSelection == true) {
                    mainOnlyDelegate.deferInstallationMonitor = false
                    AppInstallationMonitor.shared.start()
                    openMainOnly(CommandLine.arguments)
                }
            }
        }
        // Only the main window closing ends the app (not sheets, menus or alerts).
        let closeObserver = MainActor.assumeIsolated { MainOnlyDelegate.observeMainWindowClosing() }
        withExtendedLifetime((mainOnlyDelegate, closeObserver)) { app.run() }
    }
    let delegate = MainActor.assumeIsolated { AppDelegate() }
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate){app.run()}
}
