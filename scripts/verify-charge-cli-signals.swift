// Real production foreground/session signal code; only the transport is fake.
@testable import thermo
import Foundation
import ThermoKit

@main struct ChargeSignalAcceptance {
    static func main() throws {
        guard getuid() != 0, CommandLine.arguments.count == 3,
              ["int", "term"].contains(CommandLine.arguments[2]) else { exit(2) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
        guard root.lastPathComponent.hasPrefix("thermo-charge-cli-"),
              FileManager.default.fileExists(atPath: root.appendingPathComponent(".thermo-charge-cli-fixture").path) else { exit(3) }
        let path = root.appendingPathComponent("signal-" + CommandLine.arguments[2] + ".log")
        guard FileManager.default.createFile(atPath: path.path, contents: nil) else { exit(4) }
        let log = try FileHandle(forWritingTo: path); defer { try? log.close() }
        func line(_ value: String) {
            try? log.write(contentsOf: Data((value + "\n").utf8)); print(value); fflush(stdout)
        }
        var state = BatteryChargeState(); state.phase = .off; state.gate = .allowed; state.support = .smc
        let backend = ChargeBackend(read: { state }, set: { policy, id in
            state.policy = policy; state.sessionID = policy == .off ? nil : id; state.ownedByCaller = policy != .off
            state.phase = policy == .off ? .off : .holding
            state.gate = policy == .off ? .allowed : .inhibited
            state.ownership = policy == .off ? .none : .owned
            line("SET " + policy.rawValue)
        }, reset: { line("RESET") })
        try ChargeSignals.run { interrupted in
            try ChargeForegroundSession(backend: backend).run(policy: .limit80, interrupted: interrupted,
                wait: { usleep(100_000) }, emit: { value in
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    line("STATE " + String(decoding: try encoder.encode(value), as: UTF8.self))
                    if value.phase == .holding { line("READY") }
                })
        }
        guard ChargeForegroundSession.ended(state) else { exit(5) }
        line("DONE recovery-confirmed")
    }
}
