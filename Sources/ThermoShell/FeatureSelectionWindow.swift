import AppKit
import ModuleKit
import SwiftUI
import ThermoL10n

/// Stages choices without enabling features. Continue saves them before startup can prewarm anything.
@MainActor enum FeatureSelectionWindow {
    private static var window: NSWindow?
    static var isPresented: Bool { window != nil }

    static func reopenIfPresented() -> Bool {
        guard let window else { return false }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    static func show(defaults: UserDefaults = .standard, completed: @escaping @MainActor () -> Void) {
        if reopenIfPresented() { return }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 660),
                             styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = tr("Choose your Thermo features")
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: FeatureSelectionView(defaults: defaults) { enabled in
            FeatureLaunchPolicy.completeSelection(enabled, in: defaults)
            window?.close()
            window = nil
            completed()
        })
        window = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct FeatureSelectionView: View {
    @State private var selected: Set<String>
    let completed: (Set<String>) -> Void

    init(defaults: UserDefaults, completed: @escaping (Set<String>) -> Void) {
        _selected = State(initialValue: Set(BuiltinModuleManifests.all.filter {
            ModulePreferences.isEnabled($0, in: defaults)
        }.map(\.id)))
        self.completed = completed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("Choose your Thermo features")).font(.title2.bold())
            Text(tr("Start with capture, menu bar, performance and search. Add anything else you need. You can change every choice in Settings → Features."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(BuiltinModuleManifests.all, id: \.id) { feature in
                        Toggle(isOn: Binding(get: { selected.contains(feature.id) }, set: { on in
                            if on { selected.insert(feature.id) } else { selected.remove(feature.id) }
                        })) {
                            VStack(alignment: .leading, spacing: 3) {
                                Label(tr(feature.name), systemImage: feature.symbol)
                                Text(tr(feature.summary)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("first-run." + feature.id)
                    }
                }.padding(4)
            }
            HStack {
                Button(tr("Quit Thermo")) { NSApp.terminate(nil) }
                Spacer()
                Button(tr("Continue")) { completed(selected) }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 620, height: 660)
    }
}

/// Both ordinary and main-only launches use one staged continuation. Completing or reopening
/// selection cannot recurse into startup or run a second continuation.
@MainActor final class FeatureLaunchGate {
    private enum Phase { case ready, selecting, started }
    private var phase = Phase.ready
    var isSelecting: Bool { phase == .selecting }

    func launch(needsSelection: Bool,
                present: ((@escaping @MainActor () -> Void) -> Void)? = nil,
                run: @escaping @MainActor () -> Void) {
        guard phase == .ready else { return }
        if needsSelection {
            phase = .selecting
            let completed: @MainActor () -> Void = { [weak self] in
                guard let self, self.phase == .selecting else { return }
                self.phase = .started
                run()
            }
            if let present { present(completed) }
            else { FeatureSelectionWindow.show(completed: completed) }
        } else {
            phase = .started
            run()
        }
    }
}
