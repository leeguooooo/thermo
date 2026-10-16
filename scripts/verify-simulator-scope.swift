// Read-only acceptance against the selected Xcode. Link current Debug CleanKit/AgentCore/
// ThermoL10n objects with -I .build/out/Products/Debug -parse-as-library.
// The reader permits only the two inventory queries; no delete, erase, mount or shutdown.
@testable import CleanKit
import Foundation
import ThermoL10n

@main
struct SimulatorScopeAcceptance {
    struct Failure: LocalizedError { let errorDescription: String? }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(errorDescription: message) }
    }
    static func main() {
        do { try run() } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() throws {
        var queries = 0, forbidden = false
        let reader: ManagedToolScope.Runner = { argv in
            let allowed = [["/usr/bin/xcrun", "simctl", "list", "devices", "-j"], ["/usr/bin/xcrun", "simctl", "runtime", "list", "-j"]]
            guard allowed.contains(argv) else { forbidden = true; return (-1, "mutation prohibited") }
            queries += 1; return ManagedToolScope.read(argv)
        }
        let runtimeResult = reader(["/usr/bin/xcrun", "simctl", "runtime", "list", "-j"])
        let deviceResult = reader(["/usr/bin/xcrun", "simctl", "list", "devices", "-j"])
        try require(runtimeResult.0 == 0 && deviceResult.0 == 0, "inventory query failed")
        let runtimes = Array(try JSONDecoder().decode([String: Simulators.Runtime].self, from: Data(runtimeResult.1.utf8)).values)
        let devices = try JSONDecoder().decode([String: [String: [Simulators.Device]]].self, from: Data(deviceResult.1.utf8))["devices"] ?? [:]
        let home = NSHomeDirectory(), all = devices.values.flatMap { $0 }
        var runtimeScopes = 0, deviceScopes = 0, assetRoots = 0
        for runtime in runtimes {
            let command = ["/usr/bin/xcrun", "simctl", "runtime", "delete", runtime.identifier]
            if let scope = Simulators.scope(command, runtimes: runtimes, devices: devices, home: home) {
                runtimeScopes += 1; assetRoots += scope.filter { ($0 as NSString).lastPathComponent.hasSuffix(".asset") }.count
            }
        }
        for device in all where Simulators.deviceScope(device, home: home) != nil { deviceScopes += 1 }
        try require(runtimeScopes == runtimes.count && deviceScopes == all.count, "one or more reported locations could not be bound")
        var testedShutdownDevice = false
        if let device = all.first(where: { $0.state == "Shutdown" }), let data = device.dataPath {
            let command = ["/usr/bin/xcrun", "simctl", "erase", device.udid]
            guard let scope = Simulators.scope(command, runtimes: runtimes, devices: devices, home: home),
                  let identity = Simulators.reviewIdentity(command, runtimes: runtimes, devices: devices) else { throw Failure(errorDescription: "device review unavailable") }
            let item = CleanItem(id: "simulator-device/" + device.udid, category: .xcode, title: "read-only acceptance", safety: .review,
                commands: [command], commandScope: scope, commandScopes: [.init(command: command, paths: scope, reviewIdentity: identity)])
            let protected = Whitelist(file: "/fixture", entries: [data + "/thermo-probe-protected"])
            let reason = Simulators.currentScopeRefusal(command, item: item, whitelist: protected, home: home, run: reader)
            try require(reason == tr("Simulator cleanup overlaps a whitelisted location; it was kept."), "protection refused for an unexpected reason or was bypassed")
            try require(Simulators.currentScopeRefusal(command, item: item, whitelist: Whitelist(file: "/fixture", entries: [home + "/unrelated-thermo-probe"]), home: home, run: reader) == nil, "unchanged shutdown review was not accepted")
            testedShutdownDevice = true
        }
        try require(!forbidden, "a mutation reached the reader")
        let result: [String: Any] = ["runtimes": runtimes.count, "runtimeScopes": runtimeScopes, "devices": all.count,
            "deviceScopes": deviceScopes, "assetRoots": assetRoots, "queries": queries, "shutdownDeviceProtectionChecked": testedShutdownDevice, "mutationExecuted": false]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
