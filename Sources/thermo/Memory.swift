import CleanKit
import Foundation

/// Uses the same collection and grouping as the app; read-only and has no stop actions.
struct MemoryCommand {
    let app: App
    struct Report: Encodable {
        let system: MemoryBreakdown?
        let inventory: MemoryInventory
    }
    func run(_ rest: [String]) throws {
        guard rest.isEmpty else { throw CLIError("usage: thermo memory [--json]") }
        let report = Report(system: MemoryBreakdown.read(), inventory: MemoryInventory.collect())
        if app.args.has("json") {
            print(Export.json(report))
            return
        }
        print(report.system?.summary ?? tr("Memory pressure could not be read. Refresh before taking action."))
        print(tr("Memory footprint") + " / " + tr("Resident memory"))
        for program in report.inventory.programs.prefix(20) {
            let estimated = program.memoryMetric == .residentEstimate
            let footprint = program.memoryMetric == .unavailable || program.memoryMetric == .mixed ? "—" : (estimated ? "≈ " : "") + MemoryFormat.string(kibibytes: program.memoryKB)
            print("\(program.name) ×\(program.processCount)  \(footprint) / \(program.residentKB.map { MemoryFormat.string(kibibytes: $0) } ?? "—")")
            for context in program.contexts {
                print("  \(context.project ?? context.app ?? tr("Unknown project")) · PID \(context.pids.map(String.init).joined(separator: ", "))")
            }
        }
        print(tr("Footprint includes charged compressed memory. Resident memory includes shared pages; these columns cannot be subtracted to calculate swap or added to match installed RAM."))
        if !report.inventory.available { throw CLIError("process inventory unavailable") }
    }
}
