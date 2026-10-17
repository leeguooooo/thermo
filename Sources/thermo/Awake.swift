import AgentCore
import CleanKit
import Foundation
import ThermoKit
import ThermoL10n

/// `thermo awake on|off|status`: keep the Mac awake with the lid closed, through the root helper.
struct AwakeCommand {
    let app: App

    func run(_ rest: [String]) throws {
        guard rest.count <= 1 else { throw CLIError("awake takes status, on or off") }
        if app.args.has("dry-run"), let verb = rest.first, ["on","off"].contains(verb) {
            app.receipt("awake." + verb, dryRun: true, outcome: "planned", message: "Set lid-closed awake \(verb); execution validates the helper. No changes made."); return
        }
        let client = HelperClient()
        func state() throws -> LidAwakeState {
            do { return try client.blocking(timeout: 4) { try await $0.lidAwakeState() } }
            catch { throw CLIError("the helper does not answer or is too old for this; run `thermo helper install` (it asks for your password)") }
        }
        switch rest.first ?? "status" {
        case "status":
            let s = try state()
            if app.args.has("json") { print(Export.json(s)); return }
            print(s.armed ? app.style.yellow("on") + (s.lidClosed == true ? " · lid closed" : "") : "off")
            print(app.style.dim(s.heatGuard == false ? "turns itself off only at 20% battery on battery power (heat guard off; macOS still protects itself)"
                : String(format: "turns itself off at %.0f °C, at 20%% battery on battery power, or without temperature readings", s.limit)))
            if let off = s.lastAutoOff {
                print(app.style.dim("last turned itself off \(ISO8601DateFormatter().string(from: off.time)): \(off.reason) (\(off.detail))"))
            }
        case "on", "off":
            let on = rest.first == "on"
            do {
                let heatGuard = !app.args.has("no-heat-guard")
                try client.blocking(timeout: 8) { try await $0.setLidAwake(on, heatGuard: heatGuard) }
                OperationJournal.record(OperationRecord(feature: "power", action: on ? "lidAwakeOn" : "lidAwakeOff",
                                                        items: [.init(target: "disablesleep", status: "done")]))
            } catch {
                OperationJournal.record(OperationRecord(feature: "power", action: on ? "lidAwakeOn" : "lidAwakeOff",
                                                        items: [.init(target: "disablesleep", status: "failed", detail: "\(error)")]))
                throw CLIError("could not change lid-closed sleep: \(error) (thermo helper status)")
            }
            let s = try state()
            if app.args.has("json") { print(Export.json(s)); return }
            print(s.armed ? "on: the Mac stays awake with the lid closed" : "off: closing the lid puts the Mac to sleep")
            if s.armed {
                print(app.style.dim(s.heatGuard == false ? "turns itself off only at 20% battery on battery power"
                    : String(format: "turns itself off at %.0f °C or 20%% battery on battery power (--no-heat-guard to skip the heat rule)", s.limit)))
            }
        default:
            throw CLIError("usage: thermo awake [status|on|off] [--json]")
        }
    }
}
