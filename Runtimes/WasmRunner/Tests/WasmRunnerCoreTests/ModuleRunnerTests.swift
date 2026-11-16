import Foundation
import WAT
import XCTest
@testable import WasmRunnerCore

final class FakeKernel: RunnerKernel {
    var seen: [(String, Data)] = []
    func request(capability: String, payload: Data) throws -> (ok: Bool, data: Data, outcome: String?) {
        seen.append((capability, payload))
        if capability == "processes.read" { return (true, Data(#"{"processes":[]}"#.utf8), nil) }
        return (false, Data(), "denied")
    }
}

final class ModuleRunnerTests: XCTestCase {
    static func probe() throws -> [UInt8] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Fixtures/probe.wat").standardizedFileURL
        return try wat2wasm(String(contentsOf: url, encoding: .utf8))
    }

    func testCheckedInWasmMatchesItsSource() throws {
        let wasm = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Fixtures/probe.wasm").standardizedFileURL
        XCTAssertEqual(Array(try Data(contentsOf: wasm)), try Self.probe(), "rebuild probe.wasm with thermo-wat2wasm")
    }

    func testCommandsRequestsAndLimits() throws {
        let kernel = FakeKernel()
        let runner = try ModuleRunner(wasm: try Self.probe(), memoryLimit: 1 << 20, kernel: kernel)
        XCTAssertEqual(runner.exports, ["allowed", "denied", "echo", "grow", "spin", "trap"])

        let echo = try runner.call("echo", input: Data("hello".utf8), fuel: 10_000)
        XCTAssertEqual(echo.status, 0); XCTAssertEqual(String(decoding: echo.output, as: UTF8.self), "hello")

        let allowed = try runner.call("allowed", input: Data(), fuel: 10_000)
        XCTAssertEqual(allowed.status, 0); XCTAssertEqual(String(decoding: allowed.output, as: UTF8.self), #"{"processes":[]}"#)
        XCTAssertEqual(kernel.seen.first?.0, "processes.read"); XCTAssertEqual(kernel.seen.first.map { String(decoding: $0.1, as: UTF8.self) }, #"{"op":"list"}"#)

        XCTAssertEqual(try runner.call("denied", input: Data(), fuel: 10_000).status, -1)
        XCTAssertEqual(kernel.seen.last?.0, "files.read:/etc/hosts")

        XCTAssertThrowsError(try runner.call("spin", input: Data(), fuel: 100_000)) { XCTAssertEqual($0 as? RunnerError, .outOfFuel) }
        XCTAssertEqual(try runner.call("grow", input: Data(), fuel: 10_000).status, -1, "growth past the cap is refused")
        XCTAssertThrowsError(try runner.call("trap", input: Data(), fuel: 10_000)) {
            guard case .trap? = $0 as? RunnerError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try runner.call("thermo_alloc", input: Data(), fuel: 10_000))
        // Still usable after a trap and an exhausted budget.
        XCTAssertEqual(try runner.call("echo", input: Data("again".utf8), fuel: 10_000).output, Data("again".utf8))
        XCTAssertThrowsError(try runner.call("echo", input: Data(count: 70_000), fuel: 10_000)) {
            guard case .guestMemory? = $0 as? RunnerError else { return XCTFail("\($0)") }
        }
    }

    func testRefusesModulesWithoutTheABIOrWithOtherImports() throws {
        let kernel = FakeKernel()
        XCTAssertThrowsError(try ModuleRunner(wasm: try wat2wasm("(module)"), memoryLimit: 1 << 20, kernel: kernel))
        let wasi = try wat2wasm(#"(module (import "wasi_snapshot_preview1" "fd_write" (func (param i32 i32 i32 i32) (result i32))) (memory (export "memory") 1) (func (export "thermo_alloc") (param i32) (result i32) i32.const 0))"#)
        XCTAssertThrowsError(try ModuleRunner(wasm: wasi, memoryLimit: 1 << 20, kernel: kernel)) {
            guard case .badModule? = $0 as? RunnerError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try ModuleRunner(wasm: [0, 1, 2], memoryLimit: 1 << 20, kernel: kernel))
    }

    func testInitialMemoryOverTheCapIsRefused() throws {
        let big = try wat2wasm(#"(module (memory (export "memory") 64) (func (export "thermo_alloc") (param i32) (result i32) i32.const 0))"#)
        XCTAssertThrowsError(try ModuleRunner(wasm: big, memoryLimit: 1 << 20, kernel: FakeKernel()))
    }
}
