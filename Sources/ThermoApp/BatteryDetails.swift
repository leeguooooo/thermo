import SwiftUI
import ThermoKit
import ThermoL10n

struct BatteryDetails: View {
    let battery: BatteryInfo
    let fahrenheit: Bool

    static var labels: [String] { [tr("Battery"), tr("Charge"), tr("Battery health"), tr("Cycle count"), tr("Power source"), tr("Temperature"), tr("Voltage"), tr("Current"), tr("Power")] }
    static func matches(query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || labels.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    var rows: [(String, String)] {
        [
            (tr("Charge"), battery.percent.map { String(format: "%.0f%%", $0) } ?? "—"),
            (tr("Battery health"), battery.health.map { String(format: "%.0f%%", $0 * 100) } ?? "—"),
            (tr("Cycle count"), battery.cycleCount.map(String.init) ?? "—"),
            (tr("Power source"), battery.externalPower ? tr("Power adapter") : tr("On battery")),
            (tr("Temperature"), tempText(battery.temperature, fahrenheit: fahrenheit)),
            (tr("Voltage"), battery.voltage.map { String(format: "%.2f V", $0) } ?? "—"),
            (tr("Current"), battery.amperage.map { String(format: "%+.2f A", $0) } ?? "—"),
            (tr("Power"), battery.power.map { String(format: "%+.1f W", $0) } ?? "—"),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                IconTile(symbol: battery.charging ? "battery.100.bolt" : "battery.75", color: .green, size: 28)
                Text(tr("Battery")).font(.callout.weight(.semibold))
                Spacer()
                if battery.charging { Text(tr("Charging")).font(.caption).foregroundStyle(.secondary) }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack {
                        Text(row.0).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(row.1).font(.callout.monospacedDigit())
                    }
                    .padding(.horizontal, 6)
                }
            }
        }
        .padding(16).glass()
    }
}
