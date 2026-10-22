import AppKit
import SwiftUI
import ThermoL10n

/// Wi-Fi, Bluetooth and sound on one page. The three live glyphs at the top are the page's one
/// focal point; the sections under them hold the details and the few things worth a click.
struct ConnectionsPage: View {
    @ObservedObject var model: ConnectionsModel
    @State private var showAllDevices = false
    @State private var confirmDisconnect: BluetoothDevice?

    var body: some View {
        WindowPage(title: tr("Connections"), subtitle: tr("Wi-Fi, Bluetooth devices and sound output")) {
            hero
            if let error = model.actionError {
                NoticeBanner(text: error, dismiss: { model.actionError = nil })
            }
            wifiSection
            nearbySection
            bluetoothSection
            soundSection
        }
        .samplingWhileVisible { owner, active in model.setVisible(active, owner: owner) }
        .confirmationDialog(tr("Disconnect %1$@?", confirmDisconnect?.name ?? ""), isPresented: Binding(
            get: { confirmDisconnect != nil }, set: { if !$0 { confirmDisconnect = nil } }), presenting: confirmDisconnect) { device in
            Button(tr("Disconnect"), role: .destructive) { model.setConnected(false, device) }
            Button(tr("Cancel"), role: .cancel) {}
        } message: { _ in
            Text(tr("This is an input device. If it is the only one, the Mac may be left without a way to type or point."))
        }
    }

    // MARK: Hero

    var hero: some View {
        InspectorPanel {
            HStack(spacing: 0) {
                tile(symbol: "wifi", level: wifiLevel, color: model.wifi?.connected == true ? Theme.accent : Theme.textTertiary,
                     label: tr("Wi-Fi"), value: wifiTitle, detail: wifiDetail, loading: !model.wifiRead)
                divider
                tile(symbol: btSymbol, level: nil, color: btConnected.isEmpty ? Theme.textTertiary : Theme.accent,
                     label: tr("Bluetooth"), value: btTitle, detail: btDetail, loading: model.bluetooth == nil && !model.bluetoothFailed)
                divider
                tile(symbol: model.muted ? "speaker.slash.fill" : "speaker.wave.3.fill", level: model.muted ? nil : model.volume.map(Double.init),
                     color: model.muted || model.defaultOutput == nil ? Theme.textTertiary : Theme.accent,
                     label: tr("Sound"), value: soundTitle, detail: currentOutput?.name, loading: !model.wifiRead)
            }
        }
    }

    var divider: some View { Rectangle().fill(Theme.hairline).frame(width: 1).padding(.vertical, Theme.Space.l) }

    func tile(symbol: String, level: Double?, color: Color, label: String, value: String, detail: String?, loading: Bool) -> some View {
        HStack(spacing: Theme.Space.m) {
            Group {
                if let level { Image(systemName: symbol, variableValue: level) } else { Image(systemName: symbol) }
            }
            .font(.system(size: 26, weight: .medium)).foregroundStyle(color)
            .frame(width: 40, height: 40)
            .animation(Theme.standard, value: level)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(Theme.label).foregroundStyle(Theme.textTertiary)
                if loading {
                    SkeletonBar(width: 90, height: 12).padding(.vertical, 3)
                    SkeletonBar(width: 60, height: 8)
                } else {
                    Text(value).font(Theme.heading).foregroundStyle(Theme.textPrimary).lineLimit(1).contentTransition(.numericText())
                    if let detail {
                        Text(detail).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    var wifiLevel: Double? { model.wifi.map { $0.connected ? WiFiStatus.quality(rssi: $0.rssi) : 0 } }

    var wifiTitle: String {
        guard let w = model.wifi else { return tr("No Wi-Fi") }
        if !w.powerOn { return tr("Off") }
        if !w.connected { return tr("Not connected") }
        return w.ssid ?? tr("Connected")
    }

    var wifiDetail: String? {
        guard let w = model.wifi, w.connected else { return nil }
        return [WiFiStatus.qualityText(rssi: w.rssi), w.band?.rawValue].compactMap { $0 }.joined(separator: " · ")
    }

    var btConnected: [BluetoothDevice] { model.bluetooth?.devices.filter(\.connected) ?? [] }
    var btSymbol: String { btConnected.first?.symbol ?? "dot.radiowaves.left.and.right" }

    var btTitle: String {
        guard let r = model.bluetooth else { return tr("Unavailable") }
        if !r.powerOn { return tr("Off") }
        return btConnected.count == 1 ? btConnected[0].name : tr("%1$@ connected", String(btConnected.count))
    }

    var btDetail: String? {
        guard let first = btConnected.first else { return nil }
        if btConnected.count > 1 { return btConnected.map(\.name).joined(separator: ", ") }
        return levelsText(first)
    }

    var currentOutput: AudioOutput? { model.outputs.first { $0.id == model.defaultOutput } }

    var soundTitle: String {
        if model.defaultOutput == nil { return tr("No output") }
        if model.muted { return tr("Muted") }
        return model.volume.map { String(format: "%.0f%%", $0 * 100) } ?? tr("Fixed volume")
    }

    // MARK: Wi-Fi

    @ViewBuilder var wifiSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader(title: tr("Wi-Fi")) { settingsLink("com.apple.wifi-settings-extension") }
            if !model.wifiRead {
                SkeletonList(rows: 2)
            } else if let w = model.wifi, w.connected {
                InspectorPanel {
                    if w.ssid == nil { namesRow; InspectorDivider(inset: Theme.Space.l) }
                    pairs(wifiRows(w))
                }
            } else {
                InspectorPanel {
                    EmptyState(symbol: "wifi.slash", title: model.wifi == nil ? tr("This Mac has no Wi-Fi") : model.wifi?.powerOn == false ? tr("Wi-Fi is off") : tr("Not connected to a network"))
                }
            }
        }
    }

    func wifiRows(_ w: WiFiStatus) -> [(String, String)] {
        var rows: [(String, String)] = [
            (tr("Signal"), "\(w.rssi) dBm · " + WiFiStatus.qualityText(rssi: w.rssi)),
            (tr("Noise"), w.noise < 0 ? "\(w.noise) dBm · SNR \(w.rssi - w.noise) dB" : "—"),
            (tr("Link rate"), w.txRate > 0 ? String(format: "%.0f Mbps", w.txRate) : "—"),
            (tr("Channel"), [w.channel.map(String.init), w.band?.rawValue, w.widthMHz.map { "\($0) MHz" }].compactMap { $0 }.joined(separator: " · ")),
            (tr("Standard"), w.standard ?? "—"),
            (tr("Security"), w.security ?? "—"),
        ]
        if let i = w.interface { rows.append((tr("Interface"), i)) }
        if let b = w.bssid { rows.append(("BSSID", b)) }
        return rows
    }

    /// macOS hides network names from apps without Location Services; say so once, with the way to allow it.
    var namesRow: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "location.slash").foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
            Text(tr("macOS shows network names only to apps allowed to use Location Services.")).font(Theme.secondary)
                .foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.s)
            Button(model.nameAccess == .unknown ? tr("Show names") : tr("Open Location Services")) { model.requestNames() }
                .buttonStyle(PillButtonStyle()).controlSize(.small)
        }
        .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
    }

    // MARK: Nearby

    @ViewBuilder var nearbySection: some View {
        if model.wifi?.powerOn == true {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionHeader(title: tr("Nearby networks")) {
                    Button { model.scan() } label: {
                        if model.scanning { ProgressView().controlSize(.mini) } else { Text(model.nearby == nil ? tr("Scan") : tr("Scan again")) }
                    }
                    .buttonStyle(PillButtonStyle()).controlSize(.small).disabled(model.scanning)
                }
                if let error = model.scanError {
                    NoticeBanner(text: error)
                }
                if model.scanning && model.nearby == nil {
                    SkeletonList(rows: 4)
                } else if let nearby = model.nearby {
                    if nearby.isEmpty {
                        InspectorPanel { EmptyState(symbol: "wifi.exclamationmark", title: tr("No other networks heard")) }
                    } else {
                        RowList(items: Array(nearby.prefix(12)), inset: 44) { networkRow($0) }
                    }
                }
            }
        }
    }

    func networkRow(_ n: WiFiNetwork) -> some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "wifi", variableValue: WiFiStatus.quality(rssi: n.rssi))
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textSecondary).frame(width: 18)
                .accessibilityHidden(true)
            Text(n.ssid ?? tr("Name hidden")).font(Theme.body)
                .foregroundStyle(n.ssid == nil ? Theme.textTertiary : Theme.textPrimary).lineLimit(1)
            if n.secure {
                Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
                    .accessibilityLabel(tr("Secured"))
            }
            Spacer(minLength: Theme.Space.s)
            Text([n.channel.map { tr("Ch %1$@", String($0)) }, n.band?.rawValue].compactMap { $0 }.joined(separator: " · "))
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            Text("\(n.rssi) dBm").font(Theme.figure(.row, weight: .medium)).foregroundStyle(Theme.textSecondary)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, Theme.Space.s + 1)
        .accessibilityElement(children: .combine)
    }

    // MARK: Bluetooth

    var bluetoothSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader(title: tr("Bluetooth")) {
                HStack(spacing: Theme.Space.s) {
                    InfoButton(text: tr("The list comes from the system Bluetooth report. Connecting or disconnecting asks macOS for Bluetooth access the first time."))
                    settingsLink("com.apple.BluetoothSettings")
                }
            }
            if let r = model.bluetooth {
                if !r.powerOn {
                    InspectorPanel { EmptyState(symbol: "dot.radiowaves.left.and.right", title: tr("Bluetooth is off")) }
                } else if r.devices.isEmpty {
                    InspectorPanel { EmptyState(symbol: "dot.radiowaves.left.and.right", title: tr("No paired devices")) }
                } else {
                    let connected = r.devices.filter(\.connected)
                    let rest = r.devices.filter { !$0.connected }
                    let limit = max(0, 6 - connected.count)
                    RowList(items: connected + (showAllDevices ? rest : Array(rest.prefix(limit))), inset: 50) { deviceRow($0) }
                    if rest.count > limit {
                        Button(showAllDevices ? tr("Show fewer") : tr("Show all %1$@ paired devices", String(r.devices.count))) {
                            withAnimation(Theme.standard) { showAllDevices.toggle() }
                        }
                        .buttonStyle(.plain).font(Theme.secondary).foregroundStyle(Theme.accent).padding(.horizontal, 2)
                    }
                }
            } else if model.bluetoothFailed {
                InspectorPanel { EmptyState(symbol: "exclamationmark.triangle", title: tr("Could not read the Bluetooth report")) }
            } else {
                SkeletonList(rows: 3)
            }
        }
    }

    func deviceRow(_ d: BluetoothDevice) -> some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: d.symbol).font(.system(size: 16, weight: .regular))
                .foregroundStyle(d.connected ? Theme.accent : Theme.textTertiary).frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(d.name).font(Theme.rowTitle).foregroundStyle(d.connected ? Theme.textPrimary : Theme.textSecondary).lineLimit(1)
                if let levels = levelsText(d) {
                    Text(levels).font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: Theme.Space.s)
            if d.connected { StatusTag(text: tr("Connected"), color: Theme.good) }
            if model.busy.contains(d.address) {
                ProgressView().controlSize(.small).frame(width: 84)
            } else {
                Button(d.connected ? tr("Disconnect") : tr("Connect")) {
                    if d.connected && d.isInput { confirmDisconnect = d } else { model.setConnected(!d.connected, d) }
                }
                .buttonStyle(PillButtonStyle()).controlSize(.small).frame(width: 84, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, Theme.Space.s + 1)
        .hoverHighlight()
        .accessibilityElement(children: .contain)
    }

    func levelsText(_ d: BluetoothDevice) -> String? {
        guard !d.levels.isEmpty else { return nil }
        return d.levels.map { level in
            let name: String
            switch level.part {
            case .main: name = tr("Battery")
            case .left: name = tr("Left")
            case .right: name = tr("Right")
            case .box: name = tr("Case")
            }
            return "\(name) \(level.percent)%"
        }.joined(separator: " · ")
    }

    // MARK: Sound

    var soundSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader(title: tr("Sound output")) { settingsLink("com.apple.Sound-Settings.extension") }
            InspectorPanel {
                if model.defaultOutput != nil {
                    HStack(spacing: Theme.Space.m) {
                        Button { model.toggleMute() } label: {
                            Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 13)).foregroundStyle(model.muted ? Theme.caution : Theme.textSecondary).frame(width: 24)
                        }
                        .buttonStyle(.plain).help(model.muted ? tr("Unmute") : tr("Mute"))
                        .accessibilityLabel(model.muted ? tr("Unmute") : tr("Mute"))
                        if let volume = model.volume, model.volumeSettable {
                            Slider(value: Binding(get: { Double(volume) }, set: { model.setVolume(Float($0)) }), in: 0...1) { editing in
                                model.draggingVolume = editing
                            }
                            .controlSize(.small).accessibilityLabel(tr("Volume"))
                            Text(String(format: "%.0f%%", volume * 100)).font(Theme.figure(.row, weight: .medium))
                                .foregroundStyle(Theme.textSecondary).frame(width: 44, alignment: .trailing)
                        } else {
                            Text(tr("This output has a fixed volume.")).font(Theme.secondary).foregroundStyle(Theme.textTertiary)
                            Spacer()
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, Theme.Space.m)
                }
                ForEach(model.outputs) { output in
                    InspectorDivider(inset: 50)
                    outputRow(output)
                }
                if model.outputs.isEmpty && model.wifiRead {
                    EmptyState(symbol: "speaker.slash", title: tr("No sound output devices"))
                }
            }
        }
    }

    func outputRow(_ o: AudioOutput) -> some View {
        let on = o.id == model.defaultOutput
        return Button { if !on { model.select(o) } } label: {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: o.symbol).font(.system(size: 14)).foregroundStyle(on ? Theme.accent : Theme.textTertiary).frame(width: 24)
                    .accessibilityHidden(true)
                Text(o.name).font(Theme.body).foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary).lineLimit(1)
                Spacer()
                if on { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent) }
            }
            .padding(.horizontal, 14).padding(.vertical, Theme.Space.s + 1)
            .contentShape(Rectangle())
            .hoverHighlight()
        }
        .buttonStyle(.plain)
        .accessibilityValue(on ? tr("Selected") : "")
    }

    // MARK: Pieces

    func settingsLink(_ pane: String) -> some View {
        Button {
            if let url = URL(string: "x-apple.systempreferences:" + pane) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 3) {
                Text(tr("Settings")).font(Theme.caption)
                Image(systemName: "arrow.up.forward").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain).help(tr("Open in System Settings"))
    }

    /// Label–value pairs two to a row, as the battery details are laid out.
    func pairs(_ rows: [(String, String)]) -> some View {
        let pairs = stride(from: 0, to: rows.count, by: 2).map { Array(rows[$0..<min($0 + 2, rows.count)]) }
        return ForEach(Array(pairs.enumerated()), id: \.offset) { i, pair in
            if i > 0 { InspectorDivider(inset: Theme.Space.l) }
            HStack(spacing: 0) {
                ForEach(Array(pair.enumerated()), id: \.offset) { j, row in
                    if j > 0 { Rectangle().fill(Theme.hairline).frame(width: 1).padding(.vertical, Theme.Space.s) }
                    HStack(spacing: Theme.Space.s) {
                        Text(row.0).font(Theme.secondary).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        Spacer(minLength: Theme.Space.xs)
                        Text(row.1).font(Theme.figure(.row, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s)
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                }
                if pair.count == 1 { Spacer().frame(maxWidth: .infinity) }
            }
        }
    }
}
