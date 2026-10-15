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
        let pairs = stride(from: 0, to: rows.count, by: 2).map { Array(rows[$0..<min($0 + 2, rows.count)]) }
        return VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: tr("Battery")) {
                if battery.charging {
                    Label(tr("Charging"), systemImage: "bolt.fill").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                }
            }
            InspectorPanel {
                ForEach(Array(pairs.enumerated()), id: \.offset) { i, pair in
                    if i > 0 { InspectorDivider(inset: 14) }
                    HStack(spacing: 0) {
                        ForEach(Array(pair.enumerated()), id: \.offset) { j, row in
                            if j > 0 { Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1).padding(.vertical, 6) }
                            HStack(spacing: 8) {
                                Text(row.0).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(row.1).font(.system(size: 12.5, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.9))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
    }
}
