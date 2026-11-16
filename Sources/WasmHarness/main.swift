import Foundation
import ModuleKit
import WasmHost

// Runs the real ThermoWasmRunner with the probe module and checks the #46 guarantees end to end.
//   WasmHarness <ThermoWasmRunner> <probe.wasm>
// Nothing here is shipped; scripts/wasm-harness.sh builds and runs it.
let arguments = CommandLine.arguments
guard arguments.count == 3 else { print("usage: WasmHarness <runner> <probe.wasm>"); exit(2) }
let runner = URL(fileURLWithPath: arguments[1])
let wasm = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
let home = NSTemporaryDirectory() + "thermo-wasm-harness-" + UUID().uuidString
try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(atPath: home) }

var failed = 0
func check(_ ok: Bool, _ what: String) {
    print((ok ? "PASS " : "FAIL ") + what)
    if !ok { failed += 1 }
}

let manifest = ModuleManifest(id: "dev.example.wasm-probe", name: "Probe", summary: "", symbol: "cube", version: "1",
                              capabilities: [Capability(.processesRead)])
let log = ModuleAccessLog(home: home)
let broker = CapabilityBroker(manifest: manifest, home: home, log: log, handlers: [
    .processesRead: { _ in BrokerAnswer(Data(#"{"processes":[1,2,3]}"#.utf8)) },
    .filesRead: { _ in BrokerAnswer(Data("should never be read".utf8)) },
])

func run() async {
    guard WasmHost.isSupported else { print("SKIP needs macOS 15 or later"); return }
    let host = WasmHost(manifest: manifest, wasm: wasm, broker: broker,
                        limits: .init(memoryBytes: 1 << 20, callTimeout: 2, fuel: 2_000_000, suspendAfter: 100),
                        launcher: .process(runner))
    func call(_ name: String, _ input: Data = Data()) async -> Result<WasmHost.Result, WasmHost.Failure> {
        do { return .success(try await host.call(name, input: input)) } catch { return .failure(error as? WasmHost.Failure ?? .crashed) }
    }
    let echo = await call("echo", Data("hello".utf8))
    check((try? echo.get().output) == Data("hello".utf8), "echo returns its input through the pipe")
    let exports = await host.exports
    check(exports == ["allowed", "denied", "echo", "grow", "spin", "trap"], "runner lists the module's commands: \(exports)")

    let allowed = await call("allowed")
    check((try? allowed.get().output).map { String(decoding: $0, as: UTF8.self) } == #"{"processes":[1,2,3]}"#, "declared processes.read is answered by the kernel")
    let denied = await call("denied")
    check((try? denied.get().status) == -1, "undeclared files.read is refused (status \(String(describing: try? denied.get().status)))")
    let records = log.records(module: manifest.id)
    check(records.map(\.outcome) == [.allowed, .denied], "both requests are in the access log: \(records.map(\.outcome))")

    let fuel = await call("spin")
    check(fuel == .failure(.outOfFuel), "infinite loop stops at the execution budget: \(fuel)")
    let grow = await call("grow")
    check((try? grow.get().status) == -1, "memory.grow past the 1 MiB cap is refused")
    let trap = await call("trap")
    if case .failure(.trapped) = trap { check(true, "unreachable comes back as a trap") } else { check(false, "unreachable comes back as a trap: \(trap)") }
    let launchesBefore = await host.launches
    check(launchesBefore == 1, "traps and budgets keep the same runner (\(launchesBefore) launch)")

    // Without a fuel budget only the kernel's clock can stop it.
    let unmetered = WasmHost(manifest: manifest, wasm: wasm, broker: broker,
                             limits: .init(memoryBytes: 1 << 20, callTimeout: 1, fuel: nil, suspendAfter: 100),
                             launcher: .process(runner))
    let started = Date()
    let killed: Result<WasmHost.Result, WasmHost.Failure>
    do { killed = .success(try await unmetered.call("spin")) } catch { killed = .failure(error as? WasmHost.Failure ?? .crashed) }
    let took = Date().timeIntervalSince(started)
    check(killed == .failure(.timedOut) && took < 3, "kernel kills a runaway call at the deadline (\(String(format: "%.2f", took)) s)")
    let after: WasmHost.Result? = try? await unmetered.call("echo", input: Data("back".utf8))
    let relaunched = await unmetered.launches
    check(after?.output == Data("back".utf8) && relaunched == 2, "next call gets a fresh runner and works")

    let bad = WasmHost(manifest: manifest, wasm: Data([0, 97, 115, 109, 9, 9]), broker: broker, launcher: .process(runner))
    do { _ = try await bad.call("echo"); check(false, "a broken module is refused") }
    catch { if case .badModule = error as? WasmHost.Failure { check(true, "a broken module is refused") } else { check(false, "a broken module is refused: \(error)") } }

    await host.stop(); await unmetered.stop(); await bad.stop()
    check(true, "kernel (this process) is still running after kills, traps and a broken module")
}

let done = DispatchSemaphore(value: 0)
Task { await run(); done.signal() }
done.wait()
print(failed == 0 ? "wasm harness: all checks passed" : "wasm harness: \(failed) failed")
exit(failed == 0 ? 0 : 1)
