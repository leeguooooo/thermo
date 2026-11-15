import Darwin
import Foundation

package struct MenuLiveValues:Sendable {
    package var sampled=Date.distantPast
    package var cpu:Double?,memory:Double?,download:Double?,upload:Double?
    package init(sampled:Date = .distantPast,cpu:Double? = nil,memory:Double? = nil,download:Double? = nil,upload:Double? = nil){self.sampled=sampled;self.cpu=cpu;self.memory=memory;self.download=download;self.upload=upload}
}
/// Queue confined, injectable kernel counters. Never enumerates processes or reads sensors.
package final class MenuLiveSampler {
    package struct Network: Equatable {
        package var received: UInt64
        package var sent: UInt64
        package init(received:UInt64,sent:UInt64){self.received=received;self.sent=sent}
    }
    package var readCPU: () -> [UInt32]?
    private let cpuPercent:([UInt32],[UInt32])->Double?
    package init(readCPU:@escaping ()->[UInt32]?,cpuPercent:@escaping ([UInt32],[UInt32])->Double?){self.readCPU=readCPU;self.cpuPercent=cpuPercent}
    package var readMemory: () -> Double? = { SystemStats.memory().map { Double($0.usedBytes) } }
    package var readNetwork: () -> [String: Network]? = MenuLiveSampler.networkCounters
    private var cpu: (TimeInterval, [UInt32])?
    private var network: (TimeInterval, [String: Network])?

    package func reset() { cpu = nil; network = nil }

    package func sample(metrics: Set<MenuMetric>, now: TimeInterval = ProcessInfo.processInfo.systemUptime,
                date: Date = Date()) -> MenuLiveValues {
        var result = MenuLiveValues(sampled: date)
        if metrics.contains(.cpuUsage) {
            if let ticks = readCPU(), ticks.count == 4 {
                if let (then, previous) = cpu, now > then, now - then <= 15,
                   zip(ticks, previous).allSatisfy({ $0 >= $1 }) {
                    result.cpu = cpuPercent(ticks,previous)
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
    private static func networkCounters() -> [String: Network]? {
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

