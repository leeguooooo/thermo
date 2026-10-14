import CleanKit
import Foundation

struct ComputeCommand {
    let app: App
    func run(_ rest: [String]) throws {
        guard rest.isEmpty else { throw CLIError("usage: thermo activity [--json]") }
        let sampler = ComputeSampler()
        _ = sampler.sample()
        Thread.sleep(forTimeInterval: 2)
        let reading = sampler.sample()
        if app.args.has("json") { print(Export.json(reading)); return }
        func p(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0) } ?? "—" }
        print("CPU \(p(reading.cpu)) · \(reading.cores) cores")
        for d in reading.devices { print("GPU \(d.name): \(p(d.percent))") }
        print("Program CPU (100% = one core) / GPU time rate (reporting clients)")
        for program in reading.programs.sorted(by: { ($0.cpu ?? -1) > ($1.cpu ?? -1) }).prefix(30) {
            print("\(program.name) ×\(program.processes.count): \(p(program.cpu)) / \(p(program.observedGPU))")
        }
    }
}
