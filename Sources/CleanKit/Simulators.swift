import Foundation
import ThermoL10n

/// Xcode simulators: runtimes (separate disk images, invisible in the data volume's folders) and
/// device data. Removed through `xcrun simctl`, never by deleting files behind CoreSimulator's back.
enum Simulators {
    struct Runtime: Decodable {
        var identifier: String
        var version: String?
        var runtimeIdentifier: String?
        var platformIdentifier: String?
        var sizeBytes: Int64?
        var lastUsedAt: String?
        var deletable: Bool?
    }

    struct Device: Decodable {
        var udid: String
        var name: String
        var state: String?
        var isAvailable: Bool?
        var dataPath: String?
        var dataPathSize: Int64?
        var lastBootedAt: String?
    }

    static func scan(_ ctx: ScanContext) -> [CleanItem] {
        guard FS.exists("/Applications/Xcode.app") || FS.exists("/Library/Developer/CommandLineTools") else { return [] }
        let cancellation = ScanCancellation.current
        let runtimeResult = Shell.exec(["xcrun", "simctl", "runtime", "list", "-j"], timeout: 30, cancellation: cancellation)
        guard runtimeResult.0 == 0 else { return [] }
        let deviceResult = Shell.exec(["xcrun", "simctl", "list", "devices", "-j"], timeout: 30, cancellation: cancellation)
        guard deviceResult.0 == 0 else { return [] }
        let runtimesJSON = runtimeResult.1
        let devicesJSON = deviceResult.1
        let runtimes = (try? JSONDecoder().decode([String: Runtime].self, from: Data(runtimesJSON.utf8)))?.values.map { $0 } ?? []
        let byRuntime = (try? JSONDecoder().decode([String: [String: [Device]]].self, from: Data(devicesJSON.utf8)))?["devices"] ?? [:]
        return items(runtimes: runtimes, devices: byRuntime, ctx: ctx)
    }

    static func currentRemovalRefusal(_ commands: [[String]], requireUnavailable: Bool) -> String? {
        guard commands.contains(where: { $0.starts(with: ["xcrun", "simctl"]) }) else { return nil }
        let deviceResult = Shell.exec(["xcrun", "simctl", "list", "devices", "-j"], timeout: 10)
        guard deviceResult.0 == 0,
              let data = try? JSONDecoder().decode([String: [String: [Device]]].self, from: Data(deviceResult.1.utf8)),
              let devices = data["devices"] else { return tr("could not verify current simulator state") }
        var runtimes: [Runtime] = []
        if commands.contains(where: { $0.starts(with: ["xcrun", "simctl", "runtime", "delete"]) }) {
            let runtimeResult = Shell.exec(["xcrun", "simctl", "runtime", "list", "-j"], timeout: 10)
            guard runtimeResult.0 == 0, let list = try? JSONDecoder().decode([String: Runtime].self, from: Data(runtimeResult.1.utf8)) else {
                return tr("could not verify current simulator state")
            }
            runtimes = Array(list.values)
        }
        return removalRefusal(commands, runtimes: runtimes, devices: devices, requireUnavailable: requireUnavailable)
    }

    static func removalRefusal(_ commands: [[String]], runtimes: [Runtime], devices: [String: [Device]], requireUnavailable: Bool) -> String? {
        let all = devices.values.flatMap { $0 }
        for command in commands where command.starts(with: ["xcrun", "simctl"]) {
            if command.count == 5, command[2] == "runtime", command[3] == "delete" {
                guard let runtime = runtimes.first(where: { $0.identifier == command[4] }), runtime.deletable != false,
                      let identifier = runtime.runtimeIdentifier else { return tr("could not verify current simulator state") }
                if (devices[identifier] ?? []).contains(where: { $0.state != "Shutdown" }) {
                    return tr("a simulator is running or its state is unknown")
                }
            } else if command.count == 4, ["delete", "erase"].contains(command[2]), command[3] != "unavailable" {
                guard let device = all.first(where: { $0.udid == command[3] }) else { return tr("could not verify current simulator state") }
                if device.state != "Shutdown" { return tr("a simulator is running or its state is unknown") }
                if requireUnavailable && device.isAvailable != false { return tr("this simulator is available again; scan again before removing it") }
            } else { return tr("simulator cleanup needs a fresh scan with exact device IDs") }
        }
        return nil
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(_ s: String?) -> Date? { s.flatMap { iso.date(from: $0) } }

    /// "iOS 27.2" from "com.apple.CoreSimulator.SimRuntime.iOS-27-2".
    static func runtimeName(_ id: String?, version: String?) -> String {
        let platform = id?.components(separatedBy: ".").last?.components(separatedBy: "-").first ?? "Simulator"
        return [platform, version].compactMap { $0 }.joined(separator: " ")
    }

    static func items(runtimes: [Runtime], devices: [String: [Device]], ctx: ScanContext) -> [CleanItem] {
        var out: [CleanItem] = []
        let stale = ctx.staleBefore
        let days = String(ctx.options.olderThanDays)

        // Runtimes nobody has used for a while: each is a multi-GB disk image.
        for r in runtimes where r.deletable != false {
            let used = date(r.lastUsedAt)
            guard (used ?? .distantPast) < stale, let size = r.sizeBytes, size > 0 else { continue }
            let name = runtimeName(r.runtimeIdentifier, version: r.version)
            let devs = devices[r.runtimeIdentifier ?? ""] ?? []
            let booted = devs.contains { $0.state == "Booted" }
            out.append(CleanItem(
                id: "simulator-runtime/\(r.identifier)", category: .xcode,
                title: tr("Simulator runtime · %1$@", name),
                detail: used == nil ? tr("never used") : tr("last used %1$@ days ago", String(Int(ctx.now.timeIntervalSince(used!) / 86400))),
                safety: .review, bytes: size, files: 1, lastUsed: used,
                note: devs.isEmpty ? nil : tr("its %1$@ simulator device(s) are removed with it", String(devs.count)),
                blocked: booted ? tr("a simulator using it is running") : nil,
                hint: "xcrun simctl runtime delete \(r.identifier)",
                commands: [["xcrun", "simctl", "runtime", "delete", r.identifier]] + devs.map { ["xcrun", "simctl", "delete", $0.udid] }))
        }

        let all = devices.values.flatMap { $0 }
        // Devices whose runtime is gone: simctl's own cleanup.
        let unavailable = all.filter { $0.isAvailable == false }
        let lost = unavailable.reduce(Int64(0)) { $0 + ($1.dataPathSize ?? 0) }
        if lost > 0 {
            out.append(CleanItem(id: "simulator-unavailable", category: .xcode,
                                 title: tr("Simulators whose runtime is gone · %1$@", String(unavailable.count)),
                                 detail: unavailable.prefix(3).map(\.name).joined(separator: ", "),
                                 safety: .safe, bytes: lost, files: unavailable.count,
                                 hint: "thermo clean run simulator-unavailable",
                                 commands: unavailable.map { ["xcrun", "simctl", "delete", $0.udid] }))
        }

        // Big devices nobody booted lately: erasing resets their data and keeps the device.
        for (runtime, devs) in devices {
            for d in devs where d.isAvailable != false {
                let size = d.dataPathSize ?? 0
                guard size >= 500_000_000 else { continue }
                let booted = date(d.lastBootedAt)
                let touched = booted ?? d.dataPath.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }
                guard (touched ?? .distantPast) < stale else { continue }
                out.append(CleanItem(
                    id: "simulator-device/\(d.udid)", category: .xcode,
                    title: tr("Simulator data · %1$@", d.name),
                    detail: runtimeName(runtime, version: nil) + " · " + (booted == nil ? tr("not booted in %1$@ days", days)
                        : tr("last booted %1$@ days ago", String(Int(ctx.now.timeIntervalSince(booted!) / 86400)))),
                    safety: .review, bytes: size, files: 1, lastUsed: touched,
                    note: tr("erasing resets the simulator like a new device; apps installed in it are removed"),
                    blocked: d.state == "Booted" ? tr("the simulator is running") : nil,
                    hint: "xcrun simctl erase \(d.udid)",
                    commands: [["xcrun", "simctl", "erase", d.udid]]))
            }
        }
        return out
    }
}
