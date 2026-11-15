import HotkeyCore
import ThermoUI
import AppKit
import ApplicationServices
import CMenuBar
import MenuBarCore
import SwiftUI
import ThermoL10n
import ModuleKit
import NativeFeatureAPI

@MainActor final class NativeMenuBarSession: MenuBarVisibilitySession {
    private let handle: TMMenuBarSession
    init(configuration: MenuBarConfiguration) throws {
        self.handle = try TMMenuBarSession.make(allowedBundles: configuration.allowedBundles)
    }
    func activate(completion: @escaping @MainActor (String?) -> Void) {
        handle.activate { error in
            let message = error?.localizedDescription
            // System callbacks can arrive off the main thread, including during
            // invalidation. Serialize them with the controller's requests.
            Task { @MainActor in completion(message) }
        }
    }
    func invalidate() -> String? {
        do { try handle.invalidate(); return nil } catch { return error.localizedDescription }
    }
}

struct ManagedMenuBarApp: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

/// Read identities from MenuBarAgent's AX tree. Coordinates are deliberately
/// absent: macOS 27 AX rectangles have not been validated for forwarded clicks.
enum MenuBarAppDiscovery {
    static func snapshot() -> [ManagedMenuBarApp] {
        guard AXIsProcessTrusted(), let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else { return [] }
        let root = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.05)
        var found: [String: ManagedMenuBarApp] = [:]
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !queue.isEmpty && visited < 256 && ProcessInfo.processInfo.systemUptime < deadline {
            let (element, depth) = queue.removeFirst()
            visited += 1
            var pid: pid_t = 0
            if AXUIElementGetPid(element, &pid) == .success, pid != agent.processIdentifier,
               let app = NSRunningApplication(processIdentifier: pid), let bundle = app.bundleIdentifier {
                found[bundle] = ManagedMenuBarApp(id: bundle, name: app.localizedName ?? bundle)
                continue
            }
            guard depth < 7 else { continue }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
                  let children = value as? [AXUIElement] else { continue }
            for child in children.prefix(256 - visited) { queue.append((child, depth + 1)) }
        }
        return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

@MainActor final class MenuBarManager: ObservableObject {
    static let enabledKey = "menuBarManagementEnabled"
    static let autoCollapseKey = "menuBarAutoCollapseSeconds"
    @Published private(set) var enabled = false
    @Published private(set) var sections = MenuBarSections()
    @Published private(set) var reveal: MenuBarReveal = .all
    @Published private(set) var apps: [ManagedMenuBarApp] = []
    @Published private(set) var loading = false
    @Published private(set) var trusted = false
    @Published private(set) var state: MenuBarSessionController.State = .visible
    @Published private(set) var error: String?
    @Published private(set) var settingsReadable = true
    @Published private(set) var autoCollapseDelay: MenuBarAutoCollapseDelay = .disabled
    var autoCollapsePending: Bool { autoCollapse.isScheduled }
    private let autoCollapse = MenuBarAutoCollapse()
    private let defaults: UserDefaults
    private let featureEnabled: @MainActor () -> Bool
    private let recovery:MenuBarRecoveryAuthority
    private let accessibilityTrusted: @MainActor () -> Bool
    private let shortcutBackend: (any CleanScreenHotkeyBackend)?
    private let store: MenuBarSectionStore
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var permissionTimer: Timer?
    private var scanGeneration: UInt64 = 0
    private var discoveryTask:Task<Void,Never>?
    private var refreshPending=false
    private var retiring=false
    private let discover:@Sendable ()->[ManagedMenuBarApp]
    private let capabilityAvailable:@MainActor ()->Bool
    private var panelOpen = false
    private(set) var sleeping = false
    private var terminating = false
    var shortcuts:MenuBarShortcuts {recovery.shortcuts}
    private var known: [String: ManagedMenuBarApp] = [:]
    private let ownBundle: String
    private var controller:MenuBarSessionController {recovery.controller}

    var available: Bool { capabilityAvailable() }
    var discoveryRunning:Bool {discoveryTask != nil}
    var retainedMenuContent:NativeMenuContent? {recovery.retainedMenu()?.content}
    var hasHiddenAssignments: Bool { !sections.assignments.isEmpty }
    var featureOn: Bool { featureEnabled() }
    var canEdit: Bool { featureOn && settingsReadable && available }

    init(defaults: UserDefaults = .standard, initialApps: [ManagedMenuBarApp] = [],
         accessibilityTrusted: @escaping @MainActor () -> Bool = { AXIsProcessTrusted() },
         shortcutBackend: (any CleanScreenHotkeyBackend)? = nil,
         featureEnabled: @escaping @MainActor () -> Bool = { true }, controller: MenuBarSessionController? = nil,
         recovery:MenuBarRecoveryAuthority? = nil,
         capabilityAvailable:@escaping @MainActor ()->Bool = {TMMenuBarSession.isAvailable()},
         discover:@escaping @Sendable ()->[ManagedMenuBarApp] = {MenuBarAppDiscovery.snapshot()}) {
        self.capabilityAvailable=capabilityAvailable;self.discover=discover
        self.defaults = defaults
        self.featureEnabled = featureEnabled
        self.recovery = recovery ?? MenuBarRecoveryAuthority(makeController:{controller ?? MenuBarSessionController {try NativeMenuBarSession(configuration:$0)}},makeShortcuts:{toggle,restore in MenuBarShortcuts(defaults:defaults,backend:shortcutBackend,toggle:toggle,restore:restore)})
        self.accessibilityTrusted = accessibilityTrusted
        self.shortcutBackend = shortcutBackend
        self.store = MenuBarSectionStore(defaults: defaults)
        self.ownBundle = Bundle.main.bundleIdentifier ?? "dev.thermo.app"
        if let seconds = defaults.object(forKey: Self.autoCollapseKey) as? Int {
            autoCollapseDelay = MenuBarAutoCollapseDelay(rawValue: seconds) ?? .disabled
        }
        self.known = Dictionary(initialApps.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        do { sections = try store.read() }
        catch {
            settingsReadable = false
            self.error = tr("Saved menu bar sections could not be read. Nothing has been hidden.")
        }
        rebuildApps()
        self.recovery.bind(self)
        state=self.recovery.state
    }

    /// Normal app startup only. Start fully visible after relaunch so login-time
    /// apps can register before a user explicitly collapses the sections.
    func start() {
        guard featureOn else { return }
        terminating = false;retiring=false
        guard state == .visible else{updateShortcutEligibility();return}
        if defaults.bool(forKey: Self.enabledKey), settingsReadable, available, accessibilityTrusted() {
            enabled = true; trusted = true; observe()
        }
        updateShortcutEligibility()
    }

    func setPanelOpen(_ open: Bool) {
        guard !open || featureOn else { return }
        panelOpen = open
        updateAutoCollapse()
        if open { refresh() }
        else { invalidateDiscovery() }
    }

    func setEnabled(_ value: Bool) {
        guard featureOn else{if !value{recovery.restoreAll()};return}
        guard value else {
            autoCollapse.cancel()
            enabled = false; defaults.set(false, forKey: Self.enabledKey)
            reveal = .all; controller.restore(); stopObserving()
            updateShortcutEligibility()
            return
        }
        guard canEdit,state == .visible else { return }
        trusted = accessibilityTrusted()
        guard trusted else {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            error = tr("Allow Accessibility access, then enable menu bar management again.")
            return
        }
        autoCollapse.cancel()
        terminating = false
        error = nil; enabled = true; reveal = .all
        defaults.set(true, forKey: Self.enabledKey)
        observe(); refresh(); updateShortcutEligibility()
    }

    func assign(_ bundle: String, to section: MenuBarSection) {
        guard canEdit, bundle != ownBundle, MenuBarSections.isAssignable(bundle) else { return }
        var next = sections
        next.assign(bundle, to: section)
        do { try store.write(next); sections = next; apply(); updateAutoCollapse() }
        catch { self.error = error.localizedDescription }
    }

    func dragData(for bundle: String) -> Data? {
        guard canEdit, isAssignable(bundle), apps.contains(where: { $0.id == bundle }) else { return nil }
        return try? JSONEncoder().encode(MenuBarDragPayload(bundle: bundle))
    }

    @discardableResult func acceptDrop(_ data: Data, into section: MenuBarSection) -> Bool {
        guard canEdit else { return false }
        do {
            let payload = try MenuBarDragPayload.read(data, knownBundles: Set(apps.map(\.id)), ownBundle: ownBundle)
            assign(payload.bundle, to: section)
            return true
        } catch {
            self.error = tr("This drag is no longer valid. Refresh the list and try again.")
            return false
        }
    }

    func setReveal(_ reveal: MenuBarReveal) {
        guard featureOn, enabled else { return }
        self.reveal = reveal
        error = nil
        apply()
        updateAutoCollapse()
        if panelOpen { refresh() }
    }

    func restoreAll() {
        guard recovery.isCurrent(self) else{return}
        // Emergency recovery also works with disabled management or lost trust.
        error = settingsReadable ? nil : error
        reveal = .all
        autoCollapse.cancel()
        controller.restore()
        if featureOn,panelOpen { refresh() }
    }

    func prepareRecovery(){autoCollapse.cancel();reveal = .all}

    func setAutoCollapseDelay(_ delay: MenuBarAutoCollapseDelay) {
        guard featureOn else{return}
        autoCollapseDelay = delay
        defaults.set(delay.rawValue, forKey: Self.autoCollapseKey)
        updateAutoCollapse()
    }

    private func updateAutoCollapse() {
        autoCollapse.cancel()
        guard enabled, trusted, !sleeping, !panelOpen, hasHiddenAssignments,
              reveal == .hidden, state == .visible || state == .applied,
              let delay = autoCollapseDelay.nanoseconds else { return }
        autoCollapse.schedule(after: delay) { [weak self] in
            guard let self, self.enabled, !self.sleeping, !self.panelOpen, self.hasHiddenAssignments,
                  self.reveal == .hidden, self.autoCollapseDelay != .disabled else { return }
            self.setReveal(.collapsed)
        }
    }

    private func updateShortcutEligibility() {
        guard featureOn,!terminating else{recovery.reconcileKeys();return}
        _=shortcuts
        recovery.reconcileKeys()
    }

    func handleVisibilityState(_ state:MenuBarSessionController.State){recovery.receive(state)}
    func receiveVisibilityState(_ state: MenuBarSessionController.State) {
        let previous = self.state
        self.state = state
        if case let .failed(message) = state {
            autoCollapse.cancel()
            error = message
            enabled = false
            if featureOn,!terminating{defaults.set(false, forKey: Self.enabledKey)}
            stopObserving()
        } else if previous != state {
            updateAutoCollapse()
        }
        updateShortcutEligibility()
    }

    func resetUnreadableSettings() {
        guard featureOn,!settingsReadable else { return }
        if let original = defaults.object(forKey: MenuBarSectionStore.key) {
            defaults.set(original, forKey: "menuBarSections.recovery.\(UUID().uuidString)")
        }
        do {
            let empty = MenuBarSections()
            try store.write(empty); sections = empty; settingsReadable = true; error = nil
        } catch { self.error = error.localizedDescription }
    }

    func refresh() {
        guard featureOn,!terminating,!retiring else{return}
        trusted = accessibilityTrusted()
        rebuildApps()
        guard available,trusted,!sleeping else{return}
        if discoveryTask != nil{refreshPending=true;return}
        loading=true;scanGeneration &+= 1
        let generation=scanGeneration,discover=discover
        let physical=Task.detached(priority:.userInitiated){discover()}
        discoveryTask=Task{[weak self] in
            let snapshot=await physical.value
            guard let self else{return}
            self.discoveryTask=nil
            if self.scanGeneration==generation,self.featureOn,!self.retiring,!self.terminating,!self.sleeping {
                for app in snapshot{self.known[app.id]=app};self.rebuildApps()
            }
            self.loading=false
            let again=self.refreshPending;self.refreshPending=false
            if again,self.panelOpen,self.featureOn,!self.retiring,!self.terminating,!self.sleeping{self.refresh()}
        }
    }
    private func invalidateDiscovery(){scanGeneration &+= 1;loading=false;refreshPending=false}
    func finishDiscovery() async {while let task=discoveryTask{await task.value}}

    func isRunning(_ bundle: String) -> Bool { NSRunningApplication.runningApplications(withBundleIdentifier: bundle).contains { !$0.isTerminated } }
    func isAssignable(_ bundle: String) -> Bool { bundle != ownBundle && MenuBarSections.isAssignable(bundle) }

    func shutdown() {
        guard recovery.isCurrent(self) else{return}
        terminating=true;retiring=true
        autoCollapse.cancel();enabled=false;reveal = .all
        invalidateDiscovery();stopObserving();recovery.shutdown()
    }

    /// Restore native visibility before retiring shortcuts or persisting the module switch.
    func stopFeature() throws {
        autoCollapse.cancel()
        reveal = .all
        invalidateDiscovery()
        controller.restore()
        guard state == .visible else {
            throw NativeFeatureBusy(error ?? tr("Menu bar restoration could not be confirmed. Try Restore all icons before switching this feature off."))
        }
        shortcuts.shutdown()
        guard !shortcuts.uncertain else {
            throw NativeFeatureBusy(shortcuts.issue ?? tr("Menu bar shortcut release could not be confirmed. Restart Thermo."))
        }
        enabled = false; panelOpen = false;retiring=true
        stopObserving()
    }

    private func apply() {
        trusted = accessibilityTrusted()
        guard enabled, !sleeping, trusted, available else {
            autoCollapse.cancel()
            if enabled && !trusted {
                enabled = false; defaults.set(false, forKey: Self.enabledKey); stopObserving()
                error = tr("Accessibility access was removed. Menu bar management has stopped.")
            }
            // Restoration can synchronously notify us. Disable management first
            // so that callback cannot retain shortcuts after permission loss.
            // A failed restoration still keeps the recovery shortcut eligible.
            controller.restore()
            updateShortcutEligibility()
            return
        }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        controller.apply(sections.configuration(running: running, ownBundle: ownBundle, reveal: reveal))
    }

    private func rebuildApps() {
        var rows = known
        for bundle in sections.assignments.keys where rows[bundle] == nil {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
            rows[bundle] = ManagedMenuBarApp(id: bundle, name: url?.deletingPathExtension().lastPathComponent ?? bundle)
        }
        apps = rows.values.filter { $0.id != ownBundle }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func observe() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.willSleepNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleWorkspaceNotification(name)
                }
            }
            observers.append((workspace, token))
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.enabled, !self.accessibilityTrusted() else { return }
                self.apply()
            }
        }
    }

    /// Other workspace notifications can arrive after willSleep. Only didWake
    /// releases the suspension; a launch, quit or Space change must not re-hide
    /// icons or restart discovery during that interval.
    func handleWorkspaceNotification(_ name: Notification.Name) {
        if name == NSWorkspace.willSleepNotification {
            sleeping = true
            autoCollapse.cancel()
            invalidateDiscovery()
            controller.restore()
            return
        }
        if name == NSWorkspace.didWakeNotification { sleeping = false }
        guard !sleeping else { return }
        apply()
        if name == NSWorkspace.didWakeNotification { updateAutoCollapse() }
        if panelOpen { refresh() }
    }

    private func stopObserving() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        permissionTimer?.invalidate(); permissionTimer = nil
    }
}
