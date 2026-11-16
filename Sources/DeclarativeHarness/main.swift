import Foundation
import ModuleKit
import WasmHost

// Runs the declarative fixture through the real ThermoWasmRunner and checks #47's data path:
// every section kind and a menu bar item come back valid, actions reach the capability broker,
// and malformed output is refused.   DeclarativeHarness <ThermoWasmRunner> <views.wasm>
let arguments = CommandLine.arguments
guard arguments.count == 3 else { print("usage: DeclarativeHarness <runner> <views.wasm>"); exit(2) }
let runner = URL(fileURLWithPath: arguments[1])
let wasm = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
let home = NSTemporaryDirectory() + "thermo-declarative-harness-" + UUID().uuidString
try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(atPath: home) }

var failed = 0
func check(_ ok: Bool, _ what: String) { print((ok ? "PASS " : "FAIL ") + what); if !ok { failed += 1 } }

let entries: [ModuleManifest.Entry] = [.init(id: "main", kind: .page, title: "Probe", scene: "main"),
                                       .init(id: "menu", kind: .menuBarItem, title: "Probe", scene: "menu")]
func manifest(_ capabilities: [Capability]) -> ModuleManifest {
    ModuleManifest(id: "dev.example.views", name: "Views", summary: "", symbol: "cube", version: "1", capabilities: capabilities, entries: entries)
}
func module(_ m: ModuleManifest, log: ModuleAccessLog) -> (WasmHost, DeclarativeModule) {
    let broker = CapabilityBroker(manifest: m, home: home, log: log, handlers: [.processesRead: { _ in BrokerAnswer(Data(#"{"processes":[1,2,3]}"#.utf8)) }])
    let host = WasmHost(manifest: m, wasm: wasm, broker: broker, limits: .init(memoryBytes: 4 << 20, callTimeout: 3, fuel: 50_000_000), launcher: .process(runner))
    return (host, DeclarativeModule(host: host))
}

func run() async {
    guard WasmHost.isSupported else { print("SKIP needs macOS 15 or later"); return }
    let log = ModuleAccessLog(home: home)
    let (host, views) = module(manifest([Capability(.processesRead)]), log: log)
    do {
        let page = try await views.render(scene: "main", language: "en")
        let kinds = (page.sections ?? []).map { section -> String in
            switch section { case .list: "list"; case .detail: "detail"; case .form: "form"; case .card: "card" }
        }
        check(Set(kinds) == ["list", "detail", "form", "card"], "page renders list, detail, form and card: \(kinds)")
        if case let .form(_, _, fields, _)? = page.sections?.first(where: { if case .form = $0 { true } else { false } }) {
            check(fields.map(\.input) == [.text, .number, .toggle, .choice], "form carries every input kind")
        } else { check(false, "form carries every input kind") }
    } catch { check(false, "page renders: \(error)") }
    do {
        let en = try await views.render(scene: "menu", language: "en")
        let zh = try await views.render(scene: "menu", language: "zh-Hans")
        check(en.menuBarItem?.title == "Probe" && zh.menuBarItem?.title == "探针", "menu bar item renders and follows the language: \(en.menuBarItem?.title ?? "-") / \(zh.menuBarItem?.title ?? "-")")
    } catch { check(false, "menu bar item renders: \(error)") }
    do {
        let after = try await views.perform("save", values: ["name": .text("x"), "count": .number(3)], scene: "main", language: "en")
        guard case let .detail(_, fields)? = after.sections?.first else { check(false, "action returns a page"); return }
        check(fields.first?.value == "processes.read allowed", "action asks the kernel for a declared capability: \(fields.first?.value ?? "-")")
    } catch { check(false, "action: \(error)") }
    do {
        let evil = try await host.call("evil")
        do { _ = try ModuleView.read(evil.output); check(false, "unknown section type is refused") }
        catch { check(error is ModuleView.Invalid, "unknown section type is refused") }
    } catch { check(false, "evil export runs: \(error)") }
    do { _ = try await views.perform("bad action!", scene: "main", language: "en"); check(false, "malformed action id is refused before the module runs") }
    catch { check(true, "malformed action id is refused before the module runs") }
    await host.stop()

    let undeclaredLog = ModuleAccessLog(home: home + "/b")
    let (bare, bareViews) = module(manifest([]), log: undeclaredLog)
    do {
        let after = try await bareViews.perform("refresh", scene: "main", language: "en")
        guard case let .detail(_, fields)? = after.sections?.first else { check(false, "undeclared capability page"); return }
        check(fields.first?.value == "refused", "an action without the declared capability is refused by the kernel")
        check(undeclaredLog.records(module: "dev.example.views").map(\.outcome) == [.denied], "the refusal is in the access log")
    } catch { check(false, "undeclared action: \(error)") }
    await bare.stop()
}

let done = DispatchSemaphore(value: 0)
Task { await run(); done.signal() }
done.wait()
print(failed == 0 ? "declarative harness: all checks passed" : "declarative harness: \(failed) failed")
exit(failed == 0 ? 0 : 1)
