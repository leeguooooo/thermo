import CleanKit
import Foundation
import ThermoKit
import ThermoL10n

enum ChargeRequest: Equatable {
    case status(probe: Bool), hold(BatteryChargePolicy, preview: Bool), recover
    init(_ rest: [String], args: Args) throws {
        guard rest.count <= 1, args.flags.isSubset(of: ["json", "no-color", "probe", "dry-run"]), args.options.isEmpty else { throw CLIError("usage: thermo charge status|limit80|full|recover [--probe|--dry-run] [--json]") }
        switch rest.first ?? "status" {
        case "status":
            guard !args.has("dry-run") else { throw CLIError("--dry-run requires charge limit80 or full") }
            self = .status(probe: args.has("probe"))
        case "limit80", "full":
            guard !args.has("probe") else { throw CLIError("--probe requires charge status") }
            self = .hold(rest[0] == "limit80" ? .limit80 : .chargeToFull, preview: args.has("dry-run"))
        case "recover":
            guard !args.has("probe"), !args.has("dry-run") else { throw CLIError("charge recover takes no probe or dry-run option") }
            self = .recover
        default: throw CLIError("usage: thermo charge status|limit80|full|recover; stop a foreground session with Ctrl-C")
        }
    }
}
extension ChargeBackend {
    static func live() -> Self {
        let client = HelperClient()
        return .init(read: { try client.blocking(timeout: 10) { try await $0.batteryChargeState() } },
                     set: { policy, id in try client.blocking(timeout: 15) { try await $0.setBatteryChargePolicy(policy, sessionID: id) } },
                     reset: { client.reset() }, record: { action, status, detail in
            OperationJournal.record(OperationRecord(feature: "battery", action: action, items: [.init(target: "charging", status: status, detail: detail)]))
        })
    }
}
struct ChargePlan: Encodable {
    let policy: BatteryChargePolicy
    var pauseAtPercent: Int? { policy == .limit80 ? 80 : nil }
    var resumeBelowPercent: Int? { policy == .limit80 ? 75 : nil }
    let changesMade = false, holdsConnection = true, forcesCharging = false
    let minimumHelperProtocol = 8
    enum CodingKeys: String, CodingKey { case policy, pauseAtPercent, resumeBelowPercent, changesMade, holdsConnection, forcesCharging, minimumHelperProtocol, fullChargeEndConditions }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(policy, forKey: .policy); try c.encodeIfPresent(pauseAtPercent, forKey: .pauseAtPercent)
        try c.encodeIfPresent(resumeBelowPercent, forKey: .resumeBelowPercent); try c.encode(changesMade, forKey: .changesMade)
        try c.encode(holdsConnection, forKey: .holdsConnection); try c.encode(forcesCharging, forKey: .forcesCharging)
        try c.encode(minimumHelperProtocol, forKey: .minimumHelperProtocol)
        if policy == .chargeToFull { try c.encode(["reported100Percent", "externalPowerDisconnected", "powerStateUnavailable", "supportChanged"], forKey: .fullChargeEndConditions) }
    }
}
struct ChargeCommand {
    let app: App
    var makeBackend: () -> ChargeBackend = { .live() }
    var probe: () -> BatteryChargeProbe = { .live() }
    static func validateStart(_ before: BatteryChargeState) throws {
        guard before.policy == .off || before.ownedByCaller else { throw CLIError("Another Thermo connection owns this policy; stop it in that process") }
        guard before.phase != .recovering, before.ownership != .uncertain else { throw CLIError("Thermo charging recovery is unconfirmed; retry recovery first", exitCode: 3) }
        guard before.support == .smc, before.percent.map({ $0.isFinite && (0...100).contains($0) }) == true,
              before.externalPower != nil, before.gate == .allowed || before.ownedByCaller else {
            throw CLIError(before.error ?? "Fresh supported charging control is unavailable; use charge status --probe")
        }
    }
    func run(_ rest: [String]) throws {
        switch try ChargeRequest(rest, args: app.args) {
        case .status(probe: true):
            let value = probe()
            if app.args.has("json") { print(Export.json(value)) }
            else {
                print("Charging support · " + value.support.rawValue + " · gate " + value.gate.rawValue)
                for row in value.registers { print("\(row.key) · " + (row.error ?? row.hex ?? "not present")) }
                print(tr("Read-only probe. Thermo session ownership and recovery were not queried."))
            }
        case .hold(let policy, preview: true):
            if app.args.has("json") { print(Export.json(ChargePlan(policy: policy))) }
            else { print(tr("Keeps the charging policy active while this command is open. Ctrl-C ends it. System charging protection still applies. No changes made.")) }
        case .status(probe: false):
            let backend = makeBackend(); defer { backend.reset() }; try show(backend.read())
        case .recover:
            let backend = makeBackend(); defer { backend.reset() }
            let before = try backend.read()
            guard before.policy == .off || before.ownedByCaller else { throw CLIError("Another Thermo connection owns this policy; stop it in that process") }
            if ChargeForegroundSession.ended(before) { try show(before); return }
            do {
                try backend.set(.off, before.sessionID ?? UUID().uuidString)
                let state = try backend.read()
                guard ChargeForegroundSession.ended(state) else { throw CLIError("Thermo charging recovery is not confirmed", exitCode: 3) }
                try show(state)
            } catch let error as CLIError { throw error }
            catch { throw CLIError(error.localizedDescription + "; recovery is unconfirmed", exitCode: 3) }
        case .hold(let policy, preview: false):
            let backend = makeBackend()
            defer { backend.reset() }
            if !app.args.has("json") { print(tr("Keep this command open. Ctrl-C ends Thermo's charging policy and checks recovery.")); fflush(stdout) }
            try ChargeSignals.run { interrupted in
                let before = try backend.read()
                try Self.validateStart(before)
                do {
                    try ChargeForegroundSession(backend: backend).run(policy: policy, interrupted: interrupted,
                        wait: { for _ in 0..<10 { if interrupted() { break }; usleep(100_000) } },
                        emit: { state in try show(state); fflush(stdout) })
                } catch let error as ChargeSessionFailure { throw CLIError(error.message, exitCode: error.recoveryConfirmed ? 1 : 3) }
                catch let error as BatteryChargeClientError { throw CLIError(error.localizedDescription) }
            }
        }
    }
    private func show(_ state: BatteryChargeState) throws {
        if app.args.has("json") {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            print(String(decoding: try encoder.encode(state), as: UTF8.self)); return
        }
        print("Charging · " + state.policy.rawValue + " · " + state.phase.rawValue + " · gate " + state.gate.rawValue)
        if let support = state.support { print("Support · " + support.rawValue) }
        if let error = state.error { print(tr(error)) }
    }
}
