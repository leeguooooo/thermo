import AppKit
import ApplicationServices
import CMenuBar
import MenuBarCore
import SwiftUI
import ThermoL10n

@MainActor private final class NativeMenuBarSession: MenuBarVisibilitySession {
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
    static let shared = MenuBarManager()
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
    private let accessibilityTrusted: @MainActor () -> Bool
    private let store: MenuBarSectionStore
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var permissionTimer: Timer?
    private var scanGeneration: UInt64 = 0
    private var panelOpen = false
    private(set) var sleeping = false
    private var known: [String: ManagedMenuBarApp] = [:]
    private let ownBundle: String
    private lazy var controller: MenuBarSessionController = {
        let controller = MenuBarSessionController { try NativeMenuBarSession(configuration: $0) }
        controller.didChange = { [weak self] state in
            guard let self else { return }
            let previous = self.state
            self.state = state
            if case let .failed(message) = state {
                self.autoCollapse.cancel()
                self.error = message
                self.enabled = false
                self.defaults.set(false, forKey: Self.enabledKey)
                self.stopObserving()
            } else if previous != state {
                self.updateAutoCollapse()
            }
        }
        return controller
    }()

    var available: Bool { TMMenuBarSession.isAvailable() }
    var hasHiddenAssignments: Bool { !sections.assignments.isEmpty }
    var canEdit: Bool { settingsReadable && available }

    init(defaults: UserDefaults = .standard, initialApps: [ManagedMenuBarApp] = [],
         accessibilityTrusted: @escaping @MainActor () -> Bool = { AXIsProcessTrusted() }) {
        self.defaults = defaults
        self.accessibilityTrusted = accessibilityTrusted
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
    }

    /// Normal app startup only. Start fully visible after relaunch so login-time
    /// apps can register before a user explicitly collapses the sections.
    func start() {
        if defaults.bool(forKey: Self.enabledKey), settingsReadable, available, accessibilityTrusted() {
            enabled = true; trusted = true; observe()
        }
    }

    func setPanelOpen(_ open: Bool) {
        panelOpen = open
        updateAutoCollapse()
        if open { refresh() }
        else { scanGeneration &+= 1; loading = false }
    }

    func setEnabled(_ value: Bool) {
        guard value else {
            autoCollapse.cancel()
            enabled = false; defaults.set(false, forKey: Self.enabledKey)
            reveal = .all; controller.restore(); stopObserving()
            return
        }
        guard canEdit else { return }
        trusted = accessibilityTrusted()
        guard trusted else {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            error = tr("Allow Accessibility access, then enable menu bar management again.")
            return
        }
        autoCollapse.cancel()
        error = nil; enabled = true; reveal = .all
        defaults.set(true, forKey: Self.enabledKey)
        observe(); refresh()
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
        guard enabled else { return }
        self.reveal = reveal
        error = nil
        apply()
        updateAutoCollapse()
        if panelOpen { refresh() }
    }

    func restoreAll() {
        // Emergency recovery also works with disabled management or lost trust.
        error = settingsReadable ? nil : error
        reveal = .all
        autoCollapse.cancel()
        controller.restore()
        if panelOpen { refresh() }
    }

    func setAutoCollapseDelay(_ delay: MenuBarAutoCollapseDelay) {
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

    func resetUnreadableSettings() {
        guard !settingsReadable else { return }
        if let original = defaults.object(forKey: MenuBarSectionStore.key) {
            defaults.set(original, forKey: "menuBarSections.recovery.\(UUID().uuidString)")
        }
        do {
            let empty = MenuBarSections()
            try store.write(empty); sections = empty; settingsReadable = true; error = nil
        } catch { self.error = error.localizedDescription }
    }

    func refresh() {
        trusted = accessibilityTrusted()
        guard !loading else { return }
        rebuildApps()
        guard available, trusted, !sleeping else { return }
        loading = true
        scanGeneration &+= 1
        let generation = scanGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let snapshot = MenuBarAppDiscovery.snapshot()
            Task { @MainActor [weak self] in
                guard let self, self.scanGeneration == generation else { return }
                self.loading = false
                for app in snapshot { self.known[app.id] = app }
                self.rebuildApps()
            }
        }
    }

    func isRunning(_ bundle: String) -> Bool { NSRunningApplication.runningApplications(withBundleIdentifier: bundle).contains { !$0.isTerminated } }
    func isAssignable(_ bundle: String) -> Bool { bundle != ownBundle && MenuBarSections.isAssignable(bundle) }

    func shutdown() {
        autoCollapse.cancel()
        enabled = false; reveal = .all
        scanGeneration &+= 1
        controller.restore(); stopObserving()
    }

    private func apply() {
        trusted = accessibilityTrusted()
        guard enabled, !sleeping, trusted, available else {
            autoCollapse.cancel()
            controller.restore()
            if enabled && !trusted {
                enabled = false; defaults.set(false, forKey: Self.enabledKey); stopObserving()
                error = tr("Accessibility access was removed. Menu bar management has stopped.")
            }
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
            scanGeneration &+= 1; loading = false
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
