import AppKit
import ModuleKit
import SwiftUI
import ThermoL10n

/// Stages choices without enabling features. Continue saves them before startup can prewarm anything.
@MainActor final class FeatureSelectionWindow {
    private var window: NSWindow?

    func show(defaults: UserDefaults = .standard, completed: @escaping @MainActor () -> Void) {
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 660),
                             styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = tr("Choose your Thermo features")
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: FeatureSelectionView(defaults: defaults) { [weak self] enabled in
            FeatureLaunchPolicy.completeSelection(enabled, in: defaults)
            self?.window?.close()
            self?.window = nil
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
