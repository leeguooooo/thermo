import SwiftUI
import ThermoL10n

struct CleanScreenButton: View {
    @ObservedObject private var model = CleanScreenModel.shared
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: {
            FeatureRow(title: tr("Clean Screen"), symbol: "sparkles.tv", note: model.issue)
        }
        .buttonStyle(.plain)
        .sheet(isPresented:$showing) { CleanScreenSetupView(model:model) }
    }
}

struct CleanScreenSetupView: View {
    @ObservedObject var model: CleanScreenModel
    @Environment(\.dismiss) private var dismiss
    var close: (() -> Void)? = nil
    @AppStorage(CleanScreenDuration.preferenceKey) private var duration = CleanScreenDuration.twoMinutes.rawValue
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Label(tr("Clean Screen"),systemImage:"sparkles.tv").font(Theme.heading)
            Text(tr("Black out connected displays while cleaning. Hold Esc or the on-screen exit control for 3 seconds to finish."))
            Picker(tr("Clean Screen duration"),selection:$duration) {
                ForEach(CleanScreenDuration.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Text(tr("Accessibility is required to intercept keyboard events. Thermo does not record typed text. Exiting stops interception; the permission remains in System Settings."))
                .font(Theme.secondary).foregroundStyle(Theme.textSecondary)
            Text(tr("Some hardware or system controls may remain active. This mode does not lock your Mac or replace the login screen."))
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            CleanScreenShortcutControls(model:CleanScreenShortcutModel.shared)
            if !model.hasAccessibility {
                Label(tr("Accessibility is not enabled for Thermo"),systemImage:"exclamationmark.triangle").foregroundStyle(Theme.caution)
                HStack {
                    Button(tr("Open Accessibility settings")) { model.openAccessibilitySettings() }
                    Button(tr("Check again")) { model.refreshPermission() }
                }
            }
            if let issue = model.issue { Text(issue).font(Theme.caption).foregroundStyle(Theme.caution) }
            HStack {
                Button(tr("Cancel")) { finish() }
                Spacer()
                Button(tr("Start Clean Screen")) {
                    model.start(CleanScreenDuration(rawValue:duration) ?? .twoMinutes)
                }.disabled(!model.hasAccessibility || model.active).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width:480).onAppear { model.refreshPermission();CleanScreenShortcutModel.enableLive() }
            .onChange(of:model.active) { if $0 { finish() } }
    }
    private func finish() { if let close { close() } else { dismiss() } }
}

struct CleanScreenOverlay: View {
    @ObservedObject var model: CleanScreenModel
    @ObservedObject private var shortcut = CleanScreenShortcutModel.shared
    var body: some View {
        ZStack {
            Color.black
            VStack(spacing:20) {
                Spacer()
                Text(tr("Clean Screen")).font(Theme.heading)
                Text(tr("Hold Esc for 3 seconds to exit")).font(Theme.body)
                if let key=shortcut.binding { Text(tr("Or press %1$@",key.label)).font(Theme.caption) }
                if let remaining = model.session?.remaining(model.now) {
                    Text(tr("Exits in %1$@ seconds",String(Int(ceil(remaining))))).monospacedDigit().font(Theme.caption)
                }
                VStack(spacing:8) {
                    Text(tr("Hold to exit")).padding(.horizontal,28).padding(.vertical,14)
                        .background(Capsule().fill(.white.opacity(0.12)))
                        .onLongPressGesture(minimumDuration:CleanScreenSession.holdDuration,pressing:{ model.holdExit($0) },perform:{ model.stop(completed:.pointer) })
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction(named:Text(tr("Exit Clean Screen"))) { model.stop() }
                    ProgressView(value:model.session?.holdProgress(model.now) ?? 0).frame(width:180)
                }
                Spacer().frame(height:55)
            }.foregroundStyle(.white.opacity(0.7))
        }.ignoresSafeArea()
    }
}
