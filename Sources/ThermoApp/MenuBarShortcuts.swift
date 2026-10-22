import Carbon
import Combine
import Foundation
import ThermoL10n

@MainActor final class MenuBarShortcuts: ObservableObject {
    static let preferenceKey = "menuBarGlobalShortcutsEnabled"
    static let toggleBinding = CleanScreenKeyBinding(keyCode: UInt32(kVK_ANSI_H),
        modifiers: UInt32(controlKey) | UInt32(optionKey), keyLabel: "H")
    static let restoreBinding = CleanScreenKeyBinding(keyCode: UInt32(kVK_ANSI_H),
        modifiers: UInt32(controlKey) | UInt32(optionKey) | UInt32(shiftKey), keyLabel: "H")
    @Published private(set) var requested: Bool
    @Published private(set) var active = false
    @Published private(set) var issue: String?
    @Published private(set) var uncertain = false
    private enum Action: Hashable { case toggle, restore }
    private let defaults: UserDefaults
    private let backend: any CleanScreenHotkeyBackend
    private let toggle: @MainActor () -> Void
    private let restore: @MainActor () -> Void
    private var eligible = false
    private var leases: [any CleanScreenHotkeyLease] = []
    private var retained: [any CleanScreenHotkeyLease] = []
    private var held: Set<Action> = []
    private var generation: UInt64 = 0

    init(defaults: UserDefaults, backend: (any CleanScreenHotkeyBackend)? = nil,
         toggle: @escaping @MainActor () -> Void, restore: @escaping @MainActor () -> Void) {
        self.defaults = defaults
        self.backend = backend ?? CarbonCleanScreenHotkeys()
        self.toggle = toggle; self.restore = restore
        requested = defaults.bool(forKey: Self.preferenceKey)
    }

    func setRequested(_ value: Bool) {
        guard !uncertain else { return }
        requested = value
        defaults.set(value, forKey: Self.preferenceKey)
        reconcile()
    }

    func setEligible(_ value: Bool) {
        guard eligible != value else { return }
        eligible = value
        reconcile()
    }

    func retry() { guard !uncertain else { return }; reconcile() }

    private func reconcile() {
        guard requested && eligible else { releaseAll(); return }
        guard !active, !uncertain else { return }
        generation &+= 1
        let request = generation
        var next: [any CleanScreenHotkeyLease] = []
        do {
            for (action, binding) in [(Action.toggle, Self.toggleBinding), (.restore, Self.restoreBinding)] {
                next.append(try backend.register(binding) { [weak self] down in
                    self?.receive(action, down: down, request: request)
                })
            }
        } catch {
            generation &+= 1
            for lease in next {
                do { try lease.release() } catch { retained.append(lease) }
            }
            uncertain = !retained.isEmpty
            issue = uncertain ? tr("Menu bar shortcut release could not be confirmed. Restart Thermo.") :
                tr("Menu bar shortcuts are unavailable. Other shortcuts are kept. Free these combinations and retry.")
            return
        }
        leases = next; held.removeAll(); issue = nil; active = true
    }

    private func receive(_ action: Action, down: Bool, request: UInt64) {
        guard request == generation, active, !uncertain, requested, eligible else { return }
        if !down { held.remove(action); return }
        guard held.insert(action).inserted else { return }
        switch action { case .toggle: toggle(); case .restore: restore() }
    }

    private func releaseAll() {
        generation &+= 1
        active = false; held.removeAll()
        let pending = leases + retained
        leases.removeAll(); retained.removeAll()
        for lease in pending {
            do { try lease.release() } catch { retained.append(lease) }
        }
        if !retained.isEmpty {
            uncertain = true
            issue = tr("Menu bar shortcut release could not be confirmed. Restart Thermo.")
        } else if !uncertain { issue = nil }
    }

    func shutdown() { eligible = false; releaseAll() }
}
