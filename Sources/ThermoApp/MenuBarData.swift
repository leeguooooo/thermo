import Darwin
import Foundation
import CleanKit
import ThermoKit
import ThermoL10n

extension MenuMetric {
    var label: String {
        switch self {
        case .cpu: return tr("CPU temperature")
        case .hottest: return tr("Hottest sensor")
        case .fan: return tr("Fan speed")
        case .power: return tr("System power")
        case .cpuUsage: return tr("CPU usage")
        case .memory: return tr("Memory used")
        case .download: return tr("Download speed")
        case .upload: return tr("Upload speed")
        }
    }
}

extension MenuClickAction {
    var label: String { self == .panel ? tr("Panel") : tr("Main console") }
}

struct MenuLiveValues {
    var sampled = Date.distantPast
    var cpu: Double?
    var memory: Double?
    var download: Double?
    var upload: Double?
}

/// Queue confined, injectable kernel counters. Never enumerates processes or reads sensors.
final class MenuLiveSampler {
    struct Network: Equatable {
        var received: UInt64
        var sent: UInt64
    }
    var readCPU: () -> [UInt32]? = QuickLoad.cpuTicks
    var readMemory: () -> Double? = { SystemStats.memory().map { Double($0.usedBytes) } }
    var readNetwork: () -> [String: Network]? = MenuLiveSampler.networkCounters
    private var cpu: (TimeInterval, [UInt32])?
    private var network: (TimeInterval, [String: Network])?

    func reset() { cpu = nil; network = nil }

    func sample(metrics: Set<MenuMetric>, now: TimeInterval = ProcessInfo.processInfo.systemUptime,
                date: Date = Date()) -> MenuLiveValues {
        var result = MenuLiveValues(sampled: date)
        if metrics.contains(.cpuUsage) {
            if let ticks = readCPU(), ticks.count == 4 {
                if let (then, previous) = cpu, now > then, now - then <= 15,
                   zip(ticks, previous).allSatisfy({ $0 >= $1 }) {
                    result.cpu = QuickLoad.cpuPercent(ticks, since: previous)
                }
                cpu = (now, ticks)
            } else { cpu = nil }
        } else { cpu = nil }
        if metrics.contains(.memory) { result.memory = readMemory() }
        if metrics.contains(.download) || metrics.contains(.upload) {
            if let counters = readNetwork(), !counters.isEmpty {
                if let (then, previous) = network, now > then, now - then <= 15,
                   Set(counters.keys) == Set(previous.keys),
                   counters.allSatisfy({ key, value in
                       guard let old = previous[key] else { return false }
                       return value.received >= old.received && value.sent >= old.sent
                   }) {
                    let elapsed = now - then
                    result.download = counters.reduce(0) { $0 + Double($1.value.received - previous[$1.key]!.received) } / elapsed
                    result.upload = counters.reduce(0) { $0 + Double($1.value.sent - previous[$1.key]!.sent) } / elapsed
                }
                network = (now, counters)
            } else { network = nil }
        } else { network = nil }
        return result
    }

    /// Preserve interface identity so replacing an interface cannot produce a false rate.
    static func networkCounters() -> [String: Network]? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var result: [String: Network] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  let data = entry.pointee.ifa_data else { continue }
            let flags = Int32(entry.pointee.ifa_flags)
            let name = String(cString: entry.pointee.ifa_name)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, name.hasPrefix("en") else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            let index = if_nametoindex(entry.pointee.ifa_name)
            // Link-layer address also distinguishes replacement hardware using the same name.
            let link = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_dl.self).pointee
            let identity = withUnsafeBytes(of: link.sdl_data) { bytes in
                bytes.dropFirst(Int(link.sdl_nlen)).prefix(Int(link.sdl_alen)).map { String(format: "%02x", $0) }.joined()
            }
            result["\(name):\(index):\(identity)"] = Network(received: UInt64(stats.ifi_ibytes), sent: UInt64(stats.ifi_obytes))
        }
        return result
    }
}

struct MenuDisplay {
    var text: String
    var tooltip: String
    var showIcon: Bool
    var stacked: Bool

    static func make(preferences p: MenuBarPreferences, snapshot: Snapshot?, live: MenuLiveValues,
                     fahrenheit: Bool, marker: String = "", now: Date = Date(),
                     sensorReadStarted: Date? = nil, validAfter: Date = .distantPast) -> MenuDisplay {
        // Snapshot timestamps mark completion. A read that straddled wake or a
        // settings change must not make its earlier observations look fresh.
        let freshSensors = snapshot.map {
            let started = sensorReadStarted ?? $0.timestamp
            return started >= validAfter && $0.timestamp >= validAfter &&
                (0...15).contains(now.timeIntervalSince(started)) &&
                (0...15).contains(now.timeIntervalSince($0.timestamp))
        } ?? false
        let freshLive = live.sampled >= validAfter && (0...15).contains(now.timeIntervalSince(live.sampled))
        func number(_ value: Double?, unit: String, scale: Double = 1) -> String {
            guard let value, value.isFinite, value >= 0 else { return "— " + unit }
            return String(format: "%.0f %@", value * scale, unit)
        }
        func value(_ metric: MenuMetric) -> String {
            switch metric {
            case .cpu, .hottest:
                let c = freshSensors ? (metric == .cpu ? snapshot?.cpu : snapshot?.maximumKnownTemperature) : nil
                return number(c.map { fahrenheit ? $0 * 9 / 5 + 32 : $0 }, unit: fahrenheit ? "°F" : "°C")
            case .fan:
                let fans = freshSensors ? snapshot?.fans : nil
                let maximum = fans?.compactMap(\.rpm).max()
                let partial = maximum != nil && (fans?.contains { $0.rpm == nil } ?? false)
                return (partial ? "≥ " : "") + number(maximum, unit: "rpm")
            case .power: return number(freshSensors ? snapshot?.systemPower : nil, unit: "W")
            case .cpuUsage: return number(freshLive ? live.cpu : nil, unit: "%")
            case .memory: return number(freshLive ? live.memory : nil, unit: "GiB", scale: 1 / 1_073_741_824)
            case .download, .upload:
                let bytes = freshLive ? (metric == .download ? live.download : live.upload) : nil
                return (metric == .download ? "↓ " : "↑ ") + number(bytes, unit: "KiB/s", scale: 1 / 1024)
            }
        }
        let metrics = [p.primary] + (p.secondary.map { [$0] } ?? [])
        let values = metrics.map(value)
        let stacked = p.layout == .stacked && metrics.count == 2 && p.presentation != .icon
        let data = p.presentation == .icon ? "" : values.joined(separator: stacked ? "\n" : " · ")
        let text = [data, marker].filter { !$0.isEmpty }.joined(separator: " ")
        let tip = zip(metrics, values).map { $0.label + ": " + $1 }.joined(separator: " · ")
        let awake = marker.isEmpty ? "" : tr("Keep awake") + ": " + marker
        return MenuDisplay(text: text, tooltip: ["Thermo", tip, awake].filter { !$0.isEmpty }.joined(separator: " · "),
                           showIcon: p.presentation != .data, stacked: stacked)
    }
}
