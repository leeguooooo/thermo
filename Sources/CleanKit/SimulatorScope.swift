import Foundation
import CryptoKit

extension Simulators {
    static let scopeIssue = "Simulator cleanup scope could not be verified; scan again before cleaning."
    static func isItem(_ item: CleanItem) -> Bool {
        item.id == "simulator-unavailable" || item.id.hasPrefix("simulator-runtime/") || item.id.hasPrefix("simulator-device/")
    }
    static func isCommand(_ command: [String]) -> Bool {
        guard let parts = ManagedToolScope.parts(command) else { return false }
        return (parts.executable as NSString).lastPathComponent == "xcrun" && parts.args.contains("simctl")
    }
    static func target(_ command: [String]) -> (runtime: Bool, id: String)? {
        guard command.count >= 2, ["xcrun", "/usr/bin/xcrun"].contains(command[0]), command[1] == "simctl" else { return nil }
        let runtime = command.count == 5 && Array(command[2...3]) == ["runtime", "delete"]
        let device = command.count == 4 && ["delete", "erase"].contains(command[2])
        guard runtime || device, let id = command.last, !id.hasPrefix("-"), !["all", "unavailable", "booted"].contains(id.lowercased()), !id.isEmpty else { return nil }
        return (runtime, id)
    }
    static func deviceScope(_ device: Device, home: String) -> [String]? {
        guard let data = device.dataPath, let logs = device.logPath,
              (logs as NSString).lastPathComponent == device.udid else { return nil }
        let directory = (data as NSString).lastPathComponent == "data" ? (data as NSString).deletingLastPathComponent : data
        guard (directory as NSString).lastPathComponent == device.udid,
              let root = ManagedToolScope.root(directory, home: home), let logRoot = ManagedToolScope.root(logs, home: home) else { return nil }
        return Array(Set([root, logRoot])).sorted()
    }
    static func scope(_ command: [String], runtimes: [Runtime], devices: [String: [Device]], home: String) -> [String]? {
        guard let target = target(command) else { return nil }
        if !target.runtime {
            let found = devices.values.flatMap { $0 }.filter { $0.udid == target.id }
            guard found.count == 1 else { return nil }
            return deviceScope(found[0], home: home)
        }
        let found = runtimes.filter { $0.identifier == target.id }
        guard found.count == 1, let identifier = found[0].runtimeIdentifier else { return nil }
        let runtime = found[0]
        let locations = [runtime.path, runtime.runtimeBundlePath, runtime.mountPath, runtime.parentMountPath]
        guard locations.allSatisfy({ $0 != nil }) else { return nil }
        var roots: [String] = []
        for raw in locations.compactMap({ $0 }) {
            guard let root = ManagedToolScope.root(raw, home: home) else { return nil }; roots.append(root)
            // runtime delete also removes its associated MobileAsset. Bind the whole asset,
            // including metadata beside AssetData, using the path reported by CoreSimulator.
            let components = raw.split(separator: "/").map(String.init)
            if let asset = components.indices.first(where: { $0 > 0 && components[$0].hasSuffix(".asset") && components[$0 - 1].hasPrefix("com_apple_MobileAsset_") }) {
                guard let assetRoot = ManagedToolScope.root("/" + components.prefix(asset + 1).joined(separator: "/"), home: home) else { return nil }; roots.append(assetRoot)
            }
        }
        for device in devices[identifier] ?? [] {
            guard let associated = deviceScope(device, home: home) else { return nil }; roots += associated
        }
        return Array(Set(roots)).sorted()
    }
    static func reviewIdentity(_ command: [String], runtimes: [Runtime], devices: [String: [Device]]) -> String? {
        guard let target = target(command) else { return nil }
        var values = [target.runtime ? "runtime" : "device", target.id]
        let selected: [Device]
        if target.runtime {
            let found = runtimes.filter { $0.identifier == target.id }
            guard found.count == 1, let runtime = found.first, let identifier = runtime.runtimeIdentifier else { return nil }
            values += [identifier, runtime.version ?? "", runtime.platformIdentifier ?? "", runtime.lastUsedAt ?? "", runtime.state ?? "", String(runtime.deletable ?? false)]
            selected = devices[identifier] ?? []
        } else {
            selected = devices.values.flatMap { $0 }.filter { $0.udid == target.id }
            guard selected.count == 1 else { return nil }
        }
        for device in selected.sorted(by: { $0.udid < $1.udid }) { values += [device.udid, device.lastUsedAt ?? "", device.lastBootedAt ?? ""] }
        guard let data = try? JSONEncoder().encode(values) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func reviewRefusal(_ item: CleanItem) -> String? {
        guard isItem(item) || (item.commands ?? []).contains(where: isCommand) else { return nil }
        guard item.paths.isEmpty, item.afterClean?.isEmpty != false,
              let commands = item.commands, !commands.isEmpty, let scopes = item.commandScopes,
              scopes.count == commands.count, Set(commands).count == commands.count,
              zip(commands, scopes).allSatisfy({ pair in pair.0 == pair.1.command && !pair.1.paths.isEmpty && pair.1.reviewIdentity != nil && target(pair.0) != nil }),
              Set(scopes.flatMap(\.paths)) == Set(item.commandScope ?? []) else { return tr(scopeIssue) }
        return nil
    }
    static func currentScopeRefusal(_ command: [String], item: CleanItem, whitelist: Whitelist, home: String,
                                    run: ManagedToolScope.Runner = { ManagedToolScope.read($0) }) -> String? {
        guard isItem(item) || isCommand(command) else { return nil }
        if let why = reviewRefusal(item) { return why }
        guard let target = target(command), let review = item.commandScopes?.first(where: { $0.command == command }) else { return tr(scopeIssue) }
        let deviceResult = run(["/usr/bin/xcrun", "simctl", "list", "devices", "-j"])
        guard deviceResult.0 == 0, let object = try? JSONDecoder().decode([String: [String: [Device]]].self, from: Data(deviceResult.1.utf8)), let devices = object["devices"] else { return tr("could not verify current simulator state") }
        var runtimes: [Runtime] = []
        if target.runtime {
            let result = run(["/usr/bin/xcrun", "simctl", "runtime", "list", "-j"])
            guard result.0 == 0, let decoded = try? JSONDecoder().decode([String: Runtime].self, from: Data(result.1.utf8)) else { return tr("could not verify current simulator state") }
            runtimes = Array(decoded.values)
        }
        if let why = removalRefusal([command], runtimes: runtimes, devices: devices, requireUnavailable: item.id == "simulator-unavailable") { return why }
        guard let current = scope(command, runtimes: runtimes, devices: devices, home: home), Set(current) == Set(review.paths),
              reviewIdentity(command, runtimes: runtimes, devices: devices) == review.reviewIdentity else { return tr(scopeIssue) }
        if current.contains(where: whitelist.protects) { return tr("Simulator cleanup overlaps a whitelisted location; it was kept.") }
        return nil
    }
}
