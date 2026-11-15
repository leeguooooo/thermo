import SystemServicesAPI
import ThermoUI
import CleanKit
import Charts
import SwiftUI
import ThermoKit
import ThermoL10n

struct SensorsPage: View {
    @ObservedObject var monitor: PerformanceModel
    @AppStorage(Settings.fahrenheit) private var fahrenheit = false

    @AppStorage(Settings.unnamedSensors) private var includeUnnamed = false
    @AppStorage("sensors.hottestFirst") private var hottestFirst = false
    @State private var search = ""

    var body: some View {
        WindowPage(title: tr("Sensors"), subtitle: Sampler.machineName) {
            if let s = monitor.snapshot {
                hero(s)
                controls
                if let battery = s.battery, BatteryDetails.matches(query: search) {
                    BatteryDetails(battery: battery, fahrenheit: fahrenheit)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: Theme.Space.l, alignment: .top)], alignment: .leading,
                          spacing: Theme.Space.l) {
                    ForEach(SensorGroup.allCases, id: \.self) { g in
                        let matched = s.temperatures.filter { $0.group == g && matches($0) }
                        // Hottest first while looking for what runs hot; the hardware order otherwise.
                        let rows = hottestFirst ? matched.sorted { $0.value > $1.value } : matched
                        if !rows.isEmpty {
                            let hot = rows.map(\.value).max()
                            section(groupName(g), headline: tempText(hot, fahrenheit: fahrenheit), color: heatColor(hot),
                                    rows: rows.map { ($0.name, $0.key, tempText($0.value, fahrenheit: fahrenheit), heatColor($0.value)) })
                        }
                    }
                    electrical(tr("Power"), s.power, "%.2f W")
                    electrical(tr("Voltage"), s.voltages, "%.3f V")
                    electrical(tr("Current"), s.currents, "%.3f A")
                }
                if !s.temperatures.contains(where: matches)
                    && !s.power.contains(where: { matches($0, category: tr("Power")) })
                    && !s.voltages.contains(where: { matches($0, category: tr("Voltage")) })
                    && !s.currents.contains(where: { matches($0, category: tr("Current")) })
                    && !(s.battery != nil && BatteryDetails.matches(query: search)) {
                    InspectorPanel { EmptyState(symbol: "magnifyingglass", title: tr("No matching sensors")) }
                }
            } else {
                controls
                SkeletonList(rows: 6)
            }
        }
        .onAppear { monitor.showUnnamedSensors(includeUnnamed) }
        .onChange(of: includeUnnamed) { monitor.showUnnamedSensors($0) }
        .onDisappear { monitor.showUnnamedSensors(false) }
    }

    /// The hottest sensor in large type, then the hottest reading of each group beside it.
    func hero(_ s: Snapshot) -> some View {
        let hottest = s.temperatures.filter { $0.value.isFinite }.max { $0.value < $1.value }
        let groups: [(String, Double)] = SensorGroup.allCases.compactMap { g in
            s.temperatures.filter { $0.group == g && $0.value.isFinite }.map(\.value).max().map { (groupName(g), $0) }
        }
        return InspectorPanel {
            HStack(alignment: .center, spacing: Theme.Space.xl) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(tr("Hottest sensor")).font(Theme.label).foregroundStyle(Theme.textTertiary)
                    Text(tempText(hottest?.value, fahrenheit: fahrenheit)).font(Theme.figure(.hero))
                        .foregroundStyle(hottest == nil ? Theme.textTertiary : heatColor(hottest?.value))
                        .contentTransition(.numericText())
                        .animation(Theme.gentle, value: hottest?.value)
                    if let hottest {
                        Text(hottest.name).font(Theme.secondary).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                }
                .frame(minWidth: 150, alignment: .leading)
                .accessibilityElement(children: .combine)
                Rectangle().fill(Theme.hairline).frame(width: 1, height: 56)
                // One row when it fits, otherwise even rows of three.
                let columns = groups.count <= 3 ? max(1, groups.count) : groups.count <= 6 ? (groups.count + 1) / 2 : 4
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.l, alignment: .leading), count: columns),
                          alignment: .leading, spacing: Theme.Space.m) {
                    ForEach(groups, id: \.0) { name, value in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                            Text(tempText(value, fahrenheit: fahrenheit)).font(Theme.figure(.large))
                                .foregroundStyle(heatColor(value)).contentTransition(.numericText())
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(Theme.Space.l)
        }
    }

    var controls: some View {
        HStack(spacing: Theme.Space.m) {
            SearchField(text: $search, prompt: tr("Search sensors by name or key"))
            Picker(tr("Sort"), selection: $hottestFirst) {
                Text(tr("Name")).tag(false)
                Text(tr("Hottest first")).tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small).help(tr("Sort sensors"))
            Toggle(tr("Include unnamed sensors"), isOn: $includeUnnamed).toggleStyle(.switch).controlSize(.mini)
                .font(Theme.secondary).foregroundStyle(Theme.textSecondary).fixedSize()
            Text(tr("Refresh: %1$@ s", String(format: "%g", monitor.interval)))
                .font(Theme.caption).foregroundStyle(Theme.textTertiary).fixedSize()
        }
    }

    func matches(_ reading: Reading) -> Bool { matches(reading, category: nil) }

    func matches(_ reading: Reading, category: String?) -> Bool {
        SensorSearch.matches(reading, query: search, category: category)
    }

    @ViewBuilder func electrical(_ title: String, _ rows: [Reading], _ f: String) -> some View {
        let rows = rows.filter { matches($0, category: title) }
        if !rows.isEmpty {
            section(title, headline: nil, color: Theme.textPrimary,
                    rows: rows.map { ($0.name, $0.key, String(format: f, $0.value), Theme.textPrimary) })
        }
    }

    func section(_ title: String, headline: String?, color: Color,
                 rows: [(String, String, String, Color)]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader(title: title) {
                if let headline {
                    Text(headline).font(Theme.sectionTitle.monospacedDigit()).foregroundStyle(color)
                        .accessibilityLabel(tr("hottest") + " " + headline)
                }
            }
            InspectorPanel {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                    if i > 0 { InspectorDivider(inset: Theme.Space.l) }
                    HStack(spacing: Theme.Space.s) {
                        Text(r.0).font(Theme.secondary).foregroundStyle(Theme.textPrimary).lineLimit(1).help(r.0)
                        Spacer(minLength: Theme.Space.xs)
                        if !r.1.hasPrefix("hid:") {
                            Text(r.1).font(Theme.mono).foregroundStyle(Theme.textTertiary)
                                .lineLimit(1).textSelection(.enabled)
                        }
                        Text(r.2).font(Theme.figure(.row)).foregroundStyle(r.3).contentTransition(.numericText())
                            .frame(width: 60, alignment: .trailing)
                    }
                    .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// Search accepts displayed category names as well as hardware names and SMC keys.
enum SensorSearch {
    static func matches(_ reading: Reading, query: String, category: String? = nil) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || reading.name.localizedCaseInsensitiveContains(query)
            || reading.key.localizedCaseInsensitiveContains(query)
            || groupName(reading.group).localizedCaseInsensitiveContains(query)
            || category?.localizedCaseInsensitiveContains(query) == true
    }
}
