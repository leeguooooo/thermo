import AppKit
import CleanKit
import IOKit.ps
import SwiftUI
import ThermoKit
import ThermoL10n

/// What the menu bar panel shows besides the sensor snapshot: CPU, GPU, memory and network over the
/// last two minutes, battery time left, and a few facts about the machine. Samples every 2 s, and
/// only while the panel is open.
@MainActor
final class PanelModel: ObservableObject {
    static let shared = PanelModel()
    static let length = 60

    @Published private(set) var cpu: [Double] = []
    @Published private(set) var gpu: [Double] = []
    @Published private(set) var memory: [Double] = []
    @Published private(set) var download: [Double] = []
    @Published private(set) var upload: Double?
    @Published private(set) var batteryMinutesLeft: Int?
    let chip = PanelModel.chipName()
    let macOS = "macOS " + ProcessInfo.processInfo.operatingSystemVersionString
        .replacingOccurrences(of: "Version ", with: "").components(separatedBy: " (").first!
    let memoryTotal = ProcessInfo.processInfo.physicalMemory

    private var timer: Timer?
    private var ticks: [UInt32]?
    private var net: (Date, UInt64, UInt64)?
    private var holding = false

    /// Every 2 s while the panel is open; every 6 s otherwise (a few cheap kernel reads), so the
    /// curves already have a history when it opens.
    private var interval: TimeInterval = 0

    func setActive(_ on: Bool) {
        let wanted: TimeInterval = on ? 2 : 6
        if on, !holding { SystemPulse.shared.hold(); holding = true }
        if !on, holding { SystemPulse.shared.release(); holding = false }
        guard wanted != interval else { return }
        interval = wanted
        timer?.invalidate()
        if on { sample() }
        timer = Timer.scheduledTimer(withTimeInterval: wanted, repeats: true) { _ in MainActor.assumeIsolated { PanelModel.shared.sample() } }
    }

    func sample() {
        if let now = QuickLoad.cpuTicks() {
            if let before = ticks, let p = QuickLoad.cpuPercent(now, since: before) { push(&cpu, p) }
            ticks = now
        }
        if let g = QuickLoad.gpuPercent() { push(&gpu, g) }
        if let m = SystemStats.memory() { push(&memory, Double(m.usedBytes) / Double(max(1, m.totalBytes)) * 100) }
        if let (rx, tx) = Self.networkBytes() {
            let now = Date()
            if let (then, rx0, tx0) = net, now > then {
                let dt = now.timeIntervalSince(then)
                // Counters can wrap or reset (interface restart); skip that step rather than show a spike.
                if rx >= rx0 { push(&download, Double(rx - rx0) / dt) }
                upload = tx >= tx0 ? Double(tx - tx0) / dt : upload
            }
            net = (now, rx, tx)
        }
        batteryMinutesLeft = Self.batteryMinutes()
    }

    private func push(_ series: inout [Double], _ value: Double) {
        guard value.isFinite else { return }
        series.append(value)
        if series.count > Self.length { series.removeFirst(series.count - Self.length) }
    }

    /// Bytes in and out over physical interfaces (Wi-Fi, Ethernet), leaving out loopback, VPN
    /// tunnels and AirDrop links so traffic is not counted twice.
    static func networkBytes() -> (UInt64, UInt64)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var rx: UInt64 = 0, tx: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  let data = entry.pointee.ifa_data else { continue }
            let flags = Int32(entry.pointee.ifa_flags)
            let name = String(cString: entry.pointee.ifa_name)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, name.hasPrefix("en") else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            rx += UInt64(stats.ifi_ibytes); tx += UInt64(stats.ifi_obytes)
        }
        return (rx, tx)
    }

    /// macOS's own estimate while on battery; nil while charging or still estimating.
    static func batteryMinutes() -> Int? {
        let seconds = IOPSGetTimeRemainingEstimate()
        guard seconds > 0, seconds != kIOPSTimeRemainingUnlimited, seconds != kIOPSTimeRemainingUnknown else { return nil }
        return Int(seconds / 60)
    }

    /// "M3", "M4 Pro", "Intel Core i7" from the CPU brand string.
    static func chipName() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        let brand = String(cString: buffer)
        if brand.hasPrefix("Apple ") { return String(brand.dropFirst(6)) }
        return brand.replacingOccurrences(of: "(R)", with: "").replacingOccurrences(of: "(TM)", with: "")
            .components(separatedBy: " CPU").first?.trimmingCharacters(in: .whitespaces) ?? brand
    }

    static var uptime: TimeInterval? {
        var boot = timeval(); var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return nil }
        return Date().timeIntervalSince1970 - Double(boot.tv_sec)
    }
}

// MARK: - Pieces

/// One card: title with a symbol, a small badge, a big value, then whatever shows the trend.
struct PanelCard<Content: View>: View {
    let title: String
    let symbol: String
    var tint: Color = .white.opacity(0.6)
    var badge: String? = nil
    var badgeTint: Color = .white.opacity(0.6)
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint).accessibilityHidden(true)
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                Spacer(minLength: 4)
                if let badge {
                    Text(badge).font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(badgeTint)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
            }
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
    }
}

struct BigValue: View {
    let value: String
    var unit: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.7)
            if let unit { Text(unit).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55)) }
        }
    }
}

/// A light line with a soft fill; draws nothing until there are two points.
struct Sparkline: View {
    let values: [Double]
    var top: Double? = nil
    var color: Color = .green

    var body: some View {
        GeometryReader { g in
            let maxValue = max(top ?? 0, values.max() ?? 0, 1e-9)
            // The newest sample sits at the right edge; a short history grows in from the right.
            let offset = PanelModel.length - values.count
            let points = values.enumerated().map { i, v in
                CGPoint(x: g.size.width * CGFloat(i + offset) / CGFloat(PanelModel.length - 1),
                        y: g.size.height * (1 - CGFloat(min(v, maxValue) / maxValue)))
            }
            if points.count > 1 {
                Path { p in p.addLines(points) }.stroke(color, style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
                Path { p in
                    p.move(to: CGPoint(x: points[0].x, y: g.size.height)); p.addLines(points)
                    p.addLine(to: CGPoint(x: points.last!.x, y: g.size.height)); p.closeSubpath()
                }.fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
            } else {
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(height: 26)
        .accessibilityHidden(true)
    }
}

struct UsageBar: View {
    let fraction: Double
    var color: Color = .blue
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(color).frame(width: g.size.width * CGFloat(min(1, max(0, fraction.isFinite ? fraction : 0))))
            }
        }
        .frame(height: 6).padding(.vertical, 10)
        .accessibilityHidden(true)
    }
}

/// A plain-SwiftUI button: it also draws in the `--render-preview` image, unlike AppKit controls.
struct PanelButton: View {
    let title: String
    var symbol: String? = nil
    var prominent = false
    var on = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 11, weight: on || prominent ? .semibold : .regular))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(.white.opacity(on || prominent ? 1 : 0.75))
            .background(Capsule().fill(prominent ? Color.accentColor : Color.white.opacity(on ? 0.22 : 0.08)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

enum PanelFormat {
    static func rate(_ bytesPerSecond: Double?) -> (String, String) {
        guard let b = bytesPerSecond, b.isFinite else { return ("—", "") }
        if b >= 1_000_000 { return (String(format: b >= 10_000_000 ? "%.0f" : "%.1f", b / 1_000_000), "MB/s") }
        return (String(format: "%.0f", b / 1000), "KB/s")
    }
    /// Memory in GiB, the way macOS labels it ("16 GB" for 16 GiB).
    static func gb(_ bytes: UInt64) -> String {
        let g = Double(bytes) / 1_073_741_824
        return g.rounded() == g || g >= 100 ? String(format: "%.0f", g) : String(format: "%.1f", g)
    }
    static func duration(minutes: Int) -> String {
        minutes >= 60 ? tr("%1$@ h %2$@ min", String(minutes / 60), String(minutes % 60)) : tr("%1$@ min", String(minutes))
    }
    static func uptime(_ seconds: TimeInterval) -> String {
        let days = Int(seconds / 86_400)
        return days >= 1 ? tr("up %1$@ d", String(days)) : tr("up %1$@ h", String(max(1, Int(seconds / 3600))))
    }
}
