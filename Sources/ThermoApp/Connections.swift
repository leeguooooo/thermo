import AgentCore
import AppKit
import AudioToolbox
import CoreAudio
import CoreLocation
import CoreWLAN
import IOBluetooth
import ThermoL10n

// MARK: - Wi-Fi

enum WiFiBand: String, Equatable, Sendable {
    case ghz24 = "2.4 GHz", ghz5 = "5 GHz", ghz6 = "6 GHz"
}

/// The Wi-Fi link as CoreWLAN reports it. The name and BSSID stay nil until macOS lets Thermo use
/// Location Services; everything else reads without permission.
struct WiFiStatus: Equatable, Sendable {
    var interface: String?
    var powerOn: Bool
    var connected: Bool
    var ssid: String?
    var bssid: String?
    var rssi: Int
    var noise: Int
    var txRate: Double
    var channel: Int?
    var band: WiFiBand?
    var widthMHz: Int?
    var security: String?
    var standard: String?

    /// 0...1 for the signal glyph; Apple's own bars step at about these levels.
    static func quality(rssi: Int) -> Double {
        guard rssi < 0 else { return 0 }
        return rssi >= -55 ? 1 : rssi >= -67 ? 0.67 : rssi >= -75 ? 0.34 : 0.1
    }

    static func qualityText(rssi: Int) -> String {
        rssi >= -55 ? tr("Excellent") : rssi >= -67 ? tr("Good") : rssi >= -75 ? tr("Fair") : tr("Weak")
    }

    /// "Wi-Fi 6E" and friends from the PHY mode; 6 GHz makes Wi-Fi 6 an E.
    static func standard(phyMode: Int, band: WiFiBand?) -> String? {
        switch phyMode {
        case 1, 2, 3: return "802.11" + ["a", "b", "g"][phyMode - 1]
        case 4: return "Wi-Fi 4"
        case 5: return "Wi-Fi 5"
        case 6: return band == .ghz6 ? "Wi-Fi 6E" : "Wi-Fi 6"
        case 7: return "Wi-Fi 7"
        default: return nil
        }
    }

    static func security(_ s: CWSecurity) -> String? {
        switch s {
        case .none: return tr("No password")
        case .WEP, .dynamicWEP: return "WEP"
        case .wpaPersonal, .wpaPersonalMixed: return "WPA"
        case .wpa2Personal, .personal: return "WPA2"
        case .wpa3Personal: return "WPA3"
        case .wpa3Transition: return "WPA2/WPA3"
        case .wpaEnterprise, .wpaEnterpriseMixed, .wpa2Enterprise, .enterprise: return tr("Enterprise")
        case .wpa3Enterprise: return tr("Enterprise") + " (WPA3)"
        case .OWE, .oweTransition: return "OWE"
        default: return nil
        }
    }

    static func band(_ c: CWChannel?) -> WiFiBand? {
        switch c?.channelBand {
        case .band2GHz: return .ghz24
        case .band5GHz: return .ghz5
        case .band6GHz: return .ghz6
        default: return nil
        }
    }

    static func width(_ c: CWChannel?) -> Int? {
        switch c?.channelWidth {
        case .width20MHz: return 20
        case .width40MHz: return 40
        case .width80MHz: return 80
        case .width160MHz: return 160
        default: return nil
        }
    }

    static func read() -> WiFiStatus? {
        guard let i = CWWiFiClient.shared().interface() else { return nil }
        let channel = i.wlanChannel()
        let rssi = i.rssiValue()
        let band = band(channel)
        return WiFiStatus(interface: i.interfaceName, powerOn: i.powerOn(),
                          connected: i.powerOn() && channel != nil && rssi < 0,
                          ssid: i.ssid(), bssid: i.bssid(), rssi: rssi, noise: i.noiseMeasurement(),
                          txRate: i.transmitRate(), channel: channel?.channelNumber, band: band, widthMHz: width(channel),
                          security: security(i.security()), standard: standard(phyMode: i.activePHYMode().rawValue, band: band))
    }
}

/// One network a scan heard; several access points with the same name are kept as the strongest.
struct WiFiNetwork: Identifiable, Equatable, Sendable {
    var id: String
    var ssid: String?
    var rssi: Int
    var channel: Int?
    var band: WiFiBand?
    var secure: Bool

    static func merge(_ networks: [WiFiNetwork], current: String?) -> [WiFiNetwork] {
        var best: [String: WiFiNetwork] = [:]
        for n in networks {
            let key = n.ssid.map { "ssid:" + $0 } ?? n.id
            if let kept = best[key], kept.rssi >= n.rssi { continue }
            best[key] = n
        }
        return best.values.filter { current == nil || $0.ssid != current }
            .sorted { $0.rssi != $1.rssi ? $0.rssi > $1.rssi : ($0.ssid ?? "") < ($1.ssid ?? "") }
    }

    /// Blocks for a few seconds; call off the main thread.
    static func scan() throws -> [WiFiNetwork] {
        guard let i = CWWiFiClient.shared().interface() else { return [] }
        return try i.scanForNetworks(withSSID: nil).enumerated().map { index, n in
            WiFiNetwork(id: n.bssid ?? "network-\(index)", ssid: n.ssid, rssi: n.rssiValue,
                        channel: n.wlanChannel?.channelNumber, band: WiFiStatus.band(n.wlanChannel),
                        secure: !n.supportsSecurity(.none))
        }
    }
}

// MARK: - Bluetooth

/// A paired device as the system Bluetooth report lists it. The report needs no permission, so the
/// page can show it on open; connecting asks macOS for Bluetooth access, and only on a click.
struct BluetoothDevice: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case headphones, speaker, keyboard, mouse, trackpad, gamepad, phone, watch, computer, tv, other }
    struct Level: Equatable, Sendable {
        enum Part: Equatable, Sendable { case main, left, right, box }
        var part: Part
        var percent: Int
    }

    var id: String { address }
    var name: String
    /// Lower case, colon separated, whichever form the source used.
    var address: String
    var connected: Bool
    var kind: Kind
    var levels: [Level]

    /// Keyboards, mice and trackpads: disconnecting one by accident can leave the Mac without input.
    var isInput: Bool { kind == .keyboard || kind == .mouse || kind == .trackpad || kind == .gamepad }

    var symbol: String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        switch kind {
        case .headphones: return "headphones"
        case .speaker: return "hifispeaker"
        case .keyboard: return "keyboard"
        case .mouse: return "magicmouse"
        case .trackpad: return "rectangle.and.hand.point.up.left"
        case .gamepad: return "gamecontroller"
        case .phone: return "iphone"
        case .watch: return "applewatch"
        case .computer: return "laptopcomputer"
        case .tv: return "appletv"
        case .other: return "dot.radiowaves.left.and.right"
        }
    }

    static func normalized(_ address: String) -> String {
        address.lowercased().replacingOccurrences(of: "-", with: ":")
    }

    static func kind(minorType: String?, name: String) -> Kind {
        switch minorType?.lowercased() ?? "" {
        case let t where t.contains("headphone") || t.contains("headset"): return .headphones
        case let t where t.contains("speaker") || t.contains("loudspeaker"): return .speaker
        case let t where t.contains("keyboard"): return .keyboard
        case let t where t.contains("trackpad"): return .trackpad
        case let t where t.contains("mouse"): return .mouse
        case let t where t.contains("gamepad") || t.contains("joystick"): return .gamepad
        default: break
        }
        let n = name.lowercased()
        if n.contains("iphone") || n.contains("ipad") { return .phone }
        if n.contains("watch") { return .watch }
        if n.contains("apple tv") { return .tv }
        if n.contains("macbook") || n.contains("imac") || n.contains("mac mini") || n.contains("mac studio") { return .computer }
        return .other
    }
}

struct BluetoothReport: Equatable, Sendable {
    var powerOn: Bool
    var devices: [BluetoothDevice]

    /// `system_profiler SPBluetoothDataType -json`: each device is a one-key object, its name the key.
    static func parse(_ data: Data) -> BluetoothReport? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controller = (root["SPBluetoothDataType"] as? [[String: Any]])?.first else { return nil }
        let state = (controller["controller_properties"] as? [String: Any])?["controller_state"] as? String
        var devices: [BluetoothDevice] = []
        var seen = Set<String>()
        for (key, connected) in [("device_connected", true), ("device_not_connected", false)] {
            for entry in controller[key] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let info = value as? [String: Any], let raw = info["device_address"] as? String else { continue }
                    let address = BluetoothDevice.normalized(raw)
                    guard seen.insert(address).inserted else { continue }
                    let levels: [BluetoothDevice.Level] = [("device_batteryLevelMain", .main), ("device_batteryLevel", .main),
                                                            ("device_batteryLevelLeft", .left), ("device_batteryLevelRight", .right),
                                                            ("device_batteryLevelCase", .box)].compactMap { field, part in
                        guard let text = info[field] as? String,
                              let percent = Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "% "))),
                              (0...100).contains(percent) else { return nil }
                        return BluetoothDevice.Level(part: part, percent: percent)
                    }
                    devices.append(BluetoothDevice(name: name, address: address, connected: connected,
                                                   kind: BluetoothDevice.kind(minorType: info["device_minorType"] as? String, name: name),
                                                   levels: levels))
                }
            }
        }
        devices.sort { $0.connected != $1.connected ? $0.connected : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return BluetoothReport(powerOn: state.map { $0 == "attrib_on" } ?? !devices.isEmpty, devices: devices)
    }

    static func read() -> BluetoothReport? {
        let r = CommandRunner.run("/usr/sbin/system_profiler", arguments: ["SPBluetoothDataType", "-json"],
                                  timeout: 20, outputLimit: 4_194_304, captureError: false)
        guard r.status == 0, !r.timedOut else { return nil }
        return parse(Data(r.output.utf8))
    }

    /// Asks the paired device to connect or disconnect. Blocks until the device answers or times out.
    static func setConnected(_ connect: Bool, address: String) -> Bool {
        guard let device = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?
            .first(where: { BluetoothDevice.normalized($0.addressString ?? "") == address }) else { return false }
        return (connect ? device.openConnection() : device.closeConnection()) == kIOReturnSuccess
    }
}

// MARK: - Sound

struct AudioOutput: Identifiable, Equatable, Sendable {
    enum Transport: Equatable, Sendable { case builtIn, bluetooth, usb, display, airPlay, virtual, other }
    var id: AudioObjectID
    var name: String
    var transport: Transport

    var symbol: String {
        switch transport {
        case .builtIn: return "laptopcomputer"
        case .bluetooth: return "headphones"
        case .usb: return "cable.connector"
        case .display: return "display"
        case .airPlay: return "airplayaudio"
        case .virtual: return "waveform"
        case .other: return "speaker.wave.2"
        }
    }
}

/// CoreAudio's output side: the devices that can play, the default one, its volume and mute.
enum AudioOutputs {
    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) -> T? {
        var a = address(selector, scope: scope)
        var v = initial
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    static func defaultOutput() -> AudioObjectID? {
        value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0))
            .flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    @discardableResult
    static func setDefault(_ id: AudioObjectID) -> Bool {
        var a = address(kAudioHardwarePropertyDefaultOutputDevice)
        var v = id
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &v) == noErr
    }

    static func devices() -> [AudioOutput] {
        var a = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
            var nameAddress = address(kAudioObjectPropertyName)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name) == noErr,
                  let text = name?.takeRetainedValue() as String? else { return nil }
            return AudioOutput(id: id, name: text, transport: transport(value(id, kAudioDevicePropertyTransportType, initial: UInt32(0))))
        }
    }

    static func transport(_ t: UInt32?) -> AudioOutput.Transport {
        switch t {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return .display
        case kAudioDeviceTransportTypeAirPlay: return .airPlay
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return .virtual
        default: return .other
        }
    }

    /// The volume the menu bar slider shows: one figure across channels.
    static func volume(_ id: AudioObjectID) -> Float? {
        var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(id, &a) else { return nil }
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioHardwareServiceGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    static func canSetVolume(_ id: AudioObjectID) -> Bool {
        var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(id, &a) && AudioHardwareServiceIsPropertySettable(id, &a, &settable) == noErr && settable.boolValue
    }

    static func setVolume(_ id: AudioObjectID, _ volume: Float) {
        var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        var v = Float32(min(1, max(0, volume)))
        AudioHardwareServiceSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    static func muted(_ id: AudioObjectID) -> Bool? {
        value(id, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, initial: UInt32(0)).map { $0 != 0 }
    }

    static func setMuted(_ id: AudioObjectID, _ muted: Bool) {
        var a = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        var v: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
    }
}

// MARK: - Model

/// What the Connections page shows. Wi-Fi and sound are read every two seconds while the page is
/// open, the Bluetooth report every fifteen; nothing here asks for a permission until a click does.
@MainActor
final class ConnectionsModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = ConnectionsModel()

    enum NameAccess: Equatable { case unknown, allowed, denied, asked }

    @Published private(set) var wifi: WiFiStatus?
    @Published private(set) var wifiRead = false
    @Published private(set) var nearby: [WiFiNetwork]?
    @Published private(set) var scanning = false
    @Published private(set) var scanError: String?
    @Published private(set) var bluetooth: BluetoothReport?
    @Published private(set) var bluetoothFailed = false
    @Published private(set) var busy: Set<String> = []
    @Published var actionError: String?
    @Published private(set) var outputs: [AudioOutput] = []
    @Published private(set) var defaultOutput: AudioObjectID?
    @Published private(set) var volume: Float?
    @Published private(set) var volumeSettable = false
    @Published private(set) var muted = false
    @Published private(set) var nameAccess: NameAccess = .unknown
    /// While the slider is held, polling must not move it back.
    var draggingVolume = false

    private var timer: Timer?
    private var ticks = 0
    private var readingBluetooth = false
    private var location: CLLocationManager?
    private var visibility = SamplingLeases()
    var samplingActive: Bool { timer != nil }

    func setVisible(_ active: Bool, owner: UUID) {
        visibility.set(owner, active: active)
        if visibility.active { start() } else { stop() }
    }

    func start() {
        guard timer == nil else { return }
        if location == nil {
            let manager = CLLocationManager()
            manager.delegate = self
            location = manager
        }
        updateAccess()
        tick(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(force: false) }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick(force: Bool) {
        wifi = WiFiStatus.read()
        wifiRead = true
        readSound()
        if force || ticks % 8 == 0 { refreshBluetooth() }
        ticks += 1
    }

    private func readSound() {
        outputs = AudioOutputs.devices()
        defaultOutput = AudioOutputs.defaultOutput()
        guard let id = defaultOutput else { volume = nil; volumeSettable = false; return }
        if !draggingVolume { volume = AudioOutputs.volume(id) }
        volumeSettable = AudioOutputs.canSetVolume(id)
        muted = AudioOutputs.muted(id) ?? false
    }

    func refreshBluetooth() {
        guard !readingBluetooth else { return }
        readingBluetooth = true
        Task.detached(priority: .utility) {
            let report = BluetoothReport.read()
            await MainActor.run {
                let m = ConnectionsModel.shared
                m.readingBluetooth = false
                if let report { m.bluetooth = report; m.bluetoothFailed = false } else if m.bluetooth == nil { m.bluetoothFailed = true }
            }
        }
    }

    func scan() {
        guard !scanning else { return }
        scanning = true
        scanError = nil
        Task.detached(priority: .userInitiated) {
            let result = Result { try WiFiNetwork.scan() }
            await MainActor.run {
                let m = ConnectionsModel.shared
                m.scanning = false
                switch result {
                case let .success(networks): m.nearby = WiFiNetwork.merge(networks, current: m.wifi?.ssid)
                case let .failure(error): m.scanError = error.localizedDescription
                }
            }
        }
    }

    func setConnected(_ connect: Bool, _ device: BluetoothDevice) {
        guard !busy.contains(device.address) else { return }
        busy.insert(device.address)
        actionError = nil
        let address = device.address, name = device.name
        Task.detached(priority: .userInitiated) {
            let ok = BluetoothReport.setConnected(connect, address: address)
            // The report lags the link by a moment.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            let report = BluetoothReport.read()
            await MainActor.run {
                let m = ConnectionsModel.shared
                m.busy.remove(address)
                if let report { m.bluetooth = report }
                if !ok { m.actionError = connect ? tr("Could not connect %1$@.", name) : tr("Could not disconnect %1$@.", name) }
            }
        }
    }

    func setVolume(_ v: Float) {
        guard let id = defaultOutput else { return }
        volume = v
        AudioOutputs.setVolume(id, v)
        if muted && v > 0 { AudioOutputs.setMuted(id, false); muted = false }
    }

    func toggleMute() {
        guard let id = defaultOutput else { return }
        AudioOutputs.setMuted(id, !muted)
        muted = AudioOutputs.muted(id) ?? !muted
    }

    func select(_ output: AudioOutput) {
        if !AudioOutputs.setDefault(output.id) { actionError = tr("Could not switch to %1$@.", output.name) }
        readSound()
    }

    /// The first click asks; after that (or once refused) the only way is System Settings.
    func requestNames() {
        switch nameAccess {
        case .unknown:
            nameAccess = .asked
            location?.requestWhenInUseAuthorization()
        case .asked, .denied:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") { NSWorkspace.shared.open(url) }
        case .allowed: break
        }
    }

    private func updateAccess() {
        guard let location else { return }
        switch location.authorizationStatus {
        case .denied, .restricted: nameAccess = .denied
        case .notDetermined: if nameAccess != .asked { nameAccess = .unknown }
        // Always or when in use; the latter has no case name on every SDK macOS 13 builds with.
        default: nameAccess = .allowed
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let m = ConnectionsModel.shared
            m.updateAccess()
            if m.timer != nil { m.wifi = WiFiStatus.read() }
        }
    }
}
