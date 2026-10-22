import SwiftUI

private struct WindowSamplingActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var windowSamplingActive: Bool {
        get { self[WindowSamplingActiveKey.self] }
        set { self[WindowSamplingActiveKey.self] = newValue }
    }
}

/// Overlapping page transitions must not let an old view stop its replacement.
struct SamplingLeases {
    private var owners = Set<UUID>()
    var active: Bool { !owners.isEmpty }
    mutating func set(_ owner: UUID, active: Bool) {
        if active { owners.insert(owner) } else { owners.remove(owner) }
    }
}

private struct VisibleSampling: ViewModifier {
    @Environment(\.windowSamplingActive) private var visible
    @State private var owner = UUID()
    @State private var running = false
    let update: (UUID, Bool) -> Void

    func body(content: Content) -> some View {
        content
            .onAppear { setActive(visible) }
            .onChange(of: visible) { setActive($0) }
            .onDisappear { setActive(false) }
    }

    private func setActive(_ active: Bool) {
        guard active != running else { return }
        running = active
        update(owner, active)
    }
}

extension View {
    func samplingWhileVisible(_ update: @escaping (UUID, Bool) -> Void) -> some View {
        modifier(VisibleSampling(update: update))
    }
}
