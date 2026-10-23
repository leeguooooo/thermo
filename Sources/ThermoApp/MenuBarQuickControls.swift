import AppKit
import ThermoL10n

/// Recreated when the native status menu opens, so the action reflects the
/// manager's current reveal state, including changes from its settings window.
@MainActor enum MenuBarQuickControls {
    static func items(model: MenuBarManager) -> [NSMenuItem] {
        var result: [NSMenuItem] = []
        if model.enabled && model.hasHiddenAssignments {
            let collapsed = model.reveal == .collapsed
            result.append(Command(title: tr(collapsed ? "Show hidden group" : "Collapse groups")) {
                // Read the live state again; the panel can change it while a
                // menu is tracking. Never enable management from this action.
                model.setReveal(model.reveal == .collapsed ? .hidden : .collapsed)
            })
        }
        if model.enabled || model.state != .visible {
            result.append(Command(title: tr("Restore all icons")) { model.restoreAll() })
        }
        return result
    }

    private final class Command: NSMenuItem {
        private let run: @MainActor () -> Void
        init(title: String, run: @escaping @MainActor () -> Void) {
            self.run = run
            super.init(title: title, action: #selector(fire), keyEquivalent: "")
            target = self
        }
        required init(coder: NSCoder) { fatalError("init(coder:) is not used") }
        @objc private func fire() { MainActor.assumeIsolated { run() } }
    }
}
