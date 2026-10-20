import AgentCore
import SwiftUI
import ThermoL10n

@MainActor
struct AudioInputAlertSettings: View {
    @AppStorage(MicrophoneAlerts.enabledKey) private var enabled = false
    @ObservedObject private var model = MicrophoneAlerts.shared
    @ObservedObject private var notifications = NotificationAccess.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(tr("Notify when an app starts using microphone or audio input"), isOn: $enabled)
                .onChange(of: enabled) { on in
                    model.configure(on)
                    if on { notifications.request() }
                }
            Text(tr("Uses system events and checks input activity every five seconds without recording. The first check establishes a baseline. Virtual audio inputs may also appear; device names are shown in alerts."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if enabled {
                status
                if model.eventCoverage == false {
                    Text(tr("Some audio events could not be monitored. Five-second checks continue, but brief activity may be missed."))
                        .font(.caption).foregroundStyle(.orange)
                }
                if notifications.state == .denied || notifications.state == .bannersDisabled {
                    Button(tr("Open notification settings")) { notifications.openSettings() }
                }
                if let error = model.deliveryError { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                ForEach(model.observation?.clients ?? [], id: \.process.pid) { client in
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(tr("Notify for %1$@", client.name), isOn: Binding(
                            get: { !model.muted.contains(client.muteKey) },
                            set: { model.setMuted(client.muteKey, !$0) }))
                        Text(client.devices.map(\.name).joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            if !model.muted.isEmpty {
                Divider()
                Text(tr("Muted apps")).font(.callout.weight(.semibold))
                ForEach(model.muted.sorted(), id: \.self) { key in
                    HStack {
                        Text(model.knownApps[key] ?? key).lineLimit(2)
                        Spacer()
                        Button(tr("Resume alerts")) { model.setMuted(key, false) }
                    }
                }
            }
        }
        .onAppear { notifications.refresh() }
    }

    @ViewBuilder private var status: some View {
        if let value = model.observation {
            if !value.complete {
                Text(tr("Audio input activity could not be fully verified. An empty list does not confirm that inputs are idle."))
                    .foregroundStyle(.orange)
            } else if value.clients.isEmpty {
                Text(tr("No active audio input was observed for this user at the last check."))
                    .foregroundStyle(.secondary)
            } else {
                Text(tr("Active audio input processes: %1$@", String(value.clients.count)))
            }
        } else {
            Text(tr("Checking audio input activity…")).foregroundStyle(.secondary)
        }
    }
}
