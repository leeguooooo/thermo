import AgentCore
import SwiftUI
import ThermoL10n

@MainActor struct CameraAlertSettings: View {
    @AppStorage(CameraAlerts.enabledKey) private var enabled = false
    @ObservedObject private var model = CameraAlerts.shared
    @ObservedObject private var notifications = NotificationAccess.shared
    var body: some View {
        // A blocked metadata read must not leave an old "idle" label looking current.
        TimelineView(.periodic(from: .now, by: 5)) { _ in content }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(tr("Notify when camera activity is detected"), isOn: $enabled).onChange(of: enabled) { on in
                model.configure(on); if on { notifications.request() }
            }
            Text(tr("Observes system-reported video input activity without capturing video. The first check establishes a baseline. Application names are not available; virtual cameras may appear."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if enabled {
                let report = model.controlReport(notificationAccess: String(describing: notifications.state))
                if report.state == "unknown" || report.state == "stale" {
                    Text(tr("Camera activity could not be fully verified. An empty list does not confirm that cameras are idle.")).foregroundStyle(.orange)
                } else if report.state == "noDevices" {
                    Text(tr("No video input devices were reported. This does not establish that every camera is visible.")).foregroundStyle(.secondary)
                } else if report.state == "idle" {
                    Text(tr("No activity was observed on the reported video inputs at the last check.")).foregroundStyle(.secondary)
                } else if report.state == "checking" {
                    Text(tr("Checking camera activity…")).foregroundStyle(.secondary)
                }
                ForEach(Array((model.observation?.devices ?? []).enumerated()), id: \.offset) { _, device in
                    LabeledContent(device.name, value: tr(device.active ? "Active" : "Idle"))
                }
                if model.eventCoverage == false {
                    Text(tr("Some camera events could not be monitored. Five-second checks continue, but brief activity may be missed."))
                        .font(.caption).foregroundStyle(.orange)
                }
                if notifications.state == .denied || notifications.state == .bannersDisabled {
                    Button(tr("Open notification settings")) { notifications.openSettings() }
                }
                if let error = model.deliveryError { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            }
        }.onAppear { notifications.refresh() }
    }
}
