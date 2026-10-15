import SwiftUI
import ThermoKit
import ThermoL10n

enum LidAwakeText {
    static func autoOff(_ off: LidAwakeState.AutoOff) -> String {
        switch off.reason {
        case "thermal": return tr("Turned off because the Mac got too hot (%1$@).", off.detail)
        case "battery": return tr("Turned off because the battery is low (%1$@).", off.detail)
        case "noReading": return tr("Turned off because the temperature could not be read.")
        default: return off.detail
        }
    }
}

/// The menu bar switch: keep the Mac awake with the lid closed, with the rules that end it said up front.
struct LidAwakeSwitch: View {
    @ObservedObject var monitor: Monitor
    @AppStorage(Settings.fahrenheit) private var fahrenheit = false

    var on: Bool { monitor.lidAwake?.armed == true || monitor.lidAwakePending }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: on ? "laptopcomputer.and.arrow.down" : "laptopcomputer").foregroundStyle(on ? Color.orange : .secondary)
                    .frame(width: 18).accessibilityHidden(true)
                Text(tr("Stay awake with the lid closed")).font(.callout)
                Spacer()
                if monitor.lidAwakeBusy || (monitor.lidAwakePending && monitor.settingUp) { ProgressView().controlSize(.small) }
                if renderingPreview {
                    // ImageRenderer cannot draw AppKit switches; a look-alike for the preview.
                    Capsule().fill(on ? Color.green : Color.secondary.opacity(0.3)).frame(width: 30, height: 18)
                        .overlay(Circle().fill(.white).padding(2), alignment: on ? .trailing : .leading)
                } else {
                    Toggle(tr("Stay awake with the lid closed"), isOn: Binding(get: { on }, set: { monitor.setLidAwake($0) }))
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                        .disabled(monitor.lidAwakeBusy || monitor.helperBusy)
                }
            }
            Text(caption).font(.caption).foregroundStyle(captionColor).fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 26)
        }
        .accessibilityElement(children: .contain)
    }

    var limit: String { monitor.lidAwake.map { tempText($0.limit, fahrenheit: fahrenheit) } ?? "—" }

    var caption: String {
        if monitor.lidAwakePending {
            return monitor.helperState == .outdated ? tr("Updating Thermo's helper first; it turns on when the helper is ready.")
                : tr("Needs Thermo's helper, which asks for approval once; it turns on when the helper is ready.")
        }
        if let state = monitor.lidAwake, state.armed {
            let closed = state.lidClosed == true ? tr("Lid closed, staying awake.") : tr("On.")
            return closed + " " + tr("Turns itself off at %1$@ or at 20%% battery on battery power.", limit)
        }
        if let off = monitor.lidAwake?.lastAutoOff, Date().timeIntervalSince(off.time) < 3600 { return LidAwakeText.autoOff(off) }
        return tr("Closing the lid puts the Mac to sleep, as usual.")
    }

    var captionColor: Color {
        if monitor.lidAwake?.armed != true, let off = monitor.lidAwake?.lastAutoOff, Date().timeIntervalSince(off.time) < 3600 { return .orange }
        return .secondary
    }
}
