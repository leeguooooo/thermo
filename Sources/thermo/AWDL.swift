import AgentCore
import Foundation
import ThermoKit
import ThermoL10n

private var awdlInterrupted: sig_atomic_t=0

enum AWDLRequest: Equatable {
    case status(probe: Bool),on(seconds: Int,preview: Bool),recover
    init(_ rest: [String],args: Args) throws {
        guard rest.count <= 1 else { throw CLIError("usage: thermo awdl status|on|recover [--seconds 300] [--dry-run]") }
        switch rest.first ?? "status" {
        case "status":
            guard args.options["seconds"] == nil,!args.has("dry-run") else { throw CLIError("--seconds and --dry-run require awdl on") }
            self = .status(probe:args.has("probe"))
        case "on":
            guard !args.has("probe"),let seconds=Int(args.options["seconds"] ?? "300"),(60...3600).contains(seconds) else {
                throw CLIError("awdl on needs --seconds 60…3600 and does not accept --probe")
            }
            self = .on(seconds:seconds,preview:args.has("dry-run"))
        case "recover":
            guard args.options["seconds"] == nil,!args.has("probe"),!args.has("dry-run") else { throw CLIError("awdl recover takes no duration, probe or dry-run options") }
            self = .recover
        default: throw CLIError("usage: thermo awdl status|on|recover")
        }
    }
}

struct AWDLCommand {
    let app: App
    func run(_ rest: [String]) throws {
        let request=try AWDLRequest(rest,args:app.args)
        switch request {
        case .status(probe:true):
            let interface=try AWDLInterfaceIO.system.read()
            if app.args.has("json") { print(Export.json(Probe(interface:interface)));return }
            print(interface.map { "awdl0 · index \($0.index) · " + ($0.up ? "up" : "down") } ?? tr("AWDL is not present on this Mac."))
            print(tr("Interface probe only; session ownership and recovery state were not queried."))
        case .on(let seconds,preview:true):
            let plan=Plan(seconds:seconds)
            if app.args.has("json") { print(Export.json(plan)) }
            else { print(tr("Pauses AWDL for up to %1$@ seconds while this command remains open. AirDrop and peer-to-peer features may be unavailable. No changes made.",String(seconds))) }
        case .status(probe:false):
            let client=HelperClient();defer { client.reset() }
            show(try state(client))
        case .recover:
            let client=HelperClient();defer { client.reset() }
            try client.blocking(timeout:15) { try await $0.endAWDL() }
            let recovered=try state(client)
            guard recovered.phase == .idle else { throw CLIError("AWDL restoration is not confirmed") }
            show(recovered)
        case .on(let seconds,preview:false): try hold(seconds:seconds)
        }
    }
    private func state(_ client: HelperClient) throws -> AWDLSessionState { try client.blocking(timeout:10) { try await $0.awdlState() } }
    private func show(_ value: AWDLSessionState) {
        if app.args.has("json") { print(Export.json(value));return }
        print("AWDL · "+value.phase.rawValue)
        if let interface=value.interface { print("awdl0 · index \(interface.index) · "+(interface.up ? "up" : "down")) }
        if let seconds=value.remainingSeconds { print(tr("Exits in %1$@ seconds",String(seconds))) }
        if value.phase == .active,!value.ownedByCaller { print(tr("Another Thermo process is using this mode.")) }
        if let error=value.error { print(error) }
    }
    private func hold(seconds: Int) throws {
        let client=HelperClient(),id=UUID().uuidString
        awdlInterrupted=0
        let oldInt=signal(SIGINT) { _ in awdlInterrupted=1 },oldTerm=signal(SIGTERM) { _ in awdlInterrupted=1 },oldHang=signal(SIGHUP) { _ in awdlInterrupted=1 }
        defer { client.reset();signal(SIGINT,oldInt);signal(SIGTERM,oldTerm);signal(SIGHUP,oldHang) }
        try client.blocking(timeout:15) { try await $0.beginAWDL(seconds:seconds,sessionID:id) }
        OperationJournal.record(OperationRecord(feature:"network",action:"awdlBegin",items:[.init(target:"awdl0",status:"done")]))
        if !app.args.has("json") { print(tr("AWDL paused. Keep this command open; Ctrl-C stops and restores the previous state.")) }
        do {
            while awdlInterrupted == 0 {
                let current=try state(client);show(current);fflush(stdout)
                if current.phase == .idle || (current.phase == .active && current.sessionID != id) {
                    OperationJournal.record(OperationRecord(feature:"network",action:"awdlRestore",items:[.init(target:"awdl0",status:"done",detail:current.lastEndReason)]));return
                }
                guard current.ownedByCaller else { throw CLIError("AWDL connection ownership changed; recovery must be checked") }
                guard current.phase == .active else { throw CLIError(current.error ?? "AWDL recovery is pending") }
                for _ in 0..<10 { if awdlInterrupted != 0 { break };usleep(100_000) }
            }
            try client.blocking(timeout:15) { try await $0.endAWDL() }
            let result=try state(client)
            guard result.phase == .idle else { throw CLIError("AWDL restoration is not confirmed") };show(result)
            OperationJournal.record(OperationRecord(feature:"network",action:"awdlRestore",items:[.init(target:"awdl0",status:"done")]))
        } catch {
            client.reset()
            OperationJournal.record(OperationRecord(feature:"network",action:"awdlRestore",items:[.init(target:"awdl0",status:"failed",detail:error.localizedDescription)]))
            throw error
        }
    }
    private struct Plan: Codable { var interface="awdl0";var seconds: Int;var changesMade=false;var holdsConnection=true;var minimumHelperProtocol=6 }
    private struct Probe: Codable { var interface: AWDLInterfaceState?;var sessionStateQueried=false }
}
