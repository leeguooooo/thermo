import AppKit
import Foundation
import ModuleDevKit
import ModuleKit
import WasmHost

/// `Thermo --module-test FOLDER [--update] [--runner PATH] [--wat2wasm PATH]`, what `thermo dev test` runs:
/// builds the module, runs every fixture through the real sandboxed runner with the fixture's fake kernel
/// answers, checks the expected text, and compares page snapshots with fixtures/<name>.png (`--update`
/// writes them). Exit 0 all passed, 1 a fixture failed, 2 usage or build.
public enum ModuleTestCommand {
    public static let flag = "--module-test"

    @MainActor public static func run(_ input: [String], output: (String) -> Void = { print($0); fflush(stdout) }) async -> Int32 {
        var arguments = input
        func option(_ name: String) -> String? {
            guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
            defer { arguments.removeSubrange(i...(i + 1)) }
            return arguments[i + 1]
        }
        func usage(_ message: String) -> Int32 { FileHandle.standardError.write(Data((message + "\n").utf8)); return 2 }
        let update = arguments.contains("--update"); arguments.removeAll { $0 == "--update" }
        let runnerPath = option("--runner"), watPath = option("--wat2wasm")
        guard arguments.count == 1 else { return usage("usage: thermo dev test [FOLDER] [--update]") }
        let source = ModuleSource(URL(fileURLWithPath: arguments[0]))
        guard WasmHost.isSupported else { return usage("WebAssembly modules need macOS 15 or later.") }
        guard let runner = runnerPath.map({ URL(fileURLWithPath: $0) }) ?? DevTools.locate("ThermoWasmRunner", environment: "THERMO_WASM_RUNNER") else {
            return usage("ThermoWasmRunner not found next to Thermo; set THERMO_WASM_RUNNER.")
        }
        guard let wat2wasm = watPath.map({ URL(fileURLWithPath: $0) }) ?? DevTools.wat2wasm() else {
            return usage("thermo-wat2wasm not found next to Thermo; set THERMO_WAT2WASM.")
        }
        let built: ModuleBuilder.Output
        do { built = try ModuleBuilder.tool(wat2wasm).build(source) } catch { return usage("build failed: \(error)") }
        let wasm = (try? Data(contentsOf: built.folder.appendingPathComponent("module.wasm"))) ?? Data()
        let fixtures: [(name: String, fixture: ModuleFixture)]
        do { fixtures = try FixtureRunner.fixtures(source) } catch { return usage("\(error)") }
        guard !fixtures.isEmpty else { return usage("no fixtures: add fixtures/<name>.json (see docs/module-development.md)") }
        let home = NSTemporaryDirectory() + "thermo-module-test-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        var failed = 0
        for (name, fixture) in fixtures {
            var result: FixtureResult
            do {
                let module = try FixtureRunner.module(built.manifest, wasm: wasm, fixture: fixture, runner: runner, home: home)
                result = await FixtureRunner.run(name, fixture, module: module)
            } catch { result = FixtureResult(name: name, problems: ["\(error)"], view: nil) }
            var note = ""
            if result.passed, fixture.snapshot == true, let view = result.view, view.sections != nil {
                let reference = source.fixturesURL.appendingPathComponent(name + ".png")
                do {
                    let png = try await PageSnapshot.png(view, manifest: built.manifest, scene: fixture.scene)
                    switch SnapshotCheck.compare(png, reference: reference, update: update) {
                    case .written: note = " (snapshot written: fixtures/\(name).png)"
                    case .matches: note = " (snapshot matches)"
                    case .differs(let reason): result.problems.append(reason)
                    }
                } catch { result.problems.append("snapshot: \(error)") }
            }
            if result.passed { output("PASS \(name)\(note)") } else { failed += 1; output("FAIL \(name): " + result.problems.joined(separator: "; ")) }
        }
        output("\(fixtures.count - failed)/\(fixtures.count) fixtures passed (\(built.manifest.id), module.wasm \(built.wasmBytes) bytes)")
        return failed == 0 ? 0 : 1
    }
}

public enum SnapshotCheck {
    public enum Outcome: Equatable { case written, matches, differs(String) }
    /// Up to 1% of pixels may differ (fonts and antialiasing vary a little between Macs).
    public static func compare(_ png: Data, reference: URL, update: Bool, threshold: Double = 0.01) -> Outcome {
        let name = reference.deletingPathExtension().lastPathComponent
        let actual = reference.deletingLastPathComponent().appendingPathComponent(name + ".actual.png")
        guard !update, let old = try? Data(contentsOf: reference) else {
            do { try png.write(to: reference); try? FileManager.default.removeItem(at: actual); return .written }
            catch { return .differs("could not write fixtures/\(name).png: \(error)") }
        }
        let share = PageSnapshot.difference(old, png)
        if let share, share <= threshold { try? FileManager.default.removeItem(at: actual); return .matches }
        try? png.write(to: actual)
        return .differs(share.map { String(format: "snapshot differs in %.1f%% of pixels; see fixtures/%@.actual.png", $0 * 100, name) }
                        ?? "snapshot size changed; see fixtures/\(name).actual.png")
    }
}
