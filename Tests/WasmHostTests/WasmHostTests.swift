import Foundation
import ModuleKit
import XCTest
@testable import WasmHost

/// Plays the runner in-process: `respond` gets every frame the host sends and returns the frames to answer with.
final class FakeRunner: WasmRunnerTransport, @unchecked Sendable {
    let lock = NSLock()
    var queue: [WasmRunnerFrame] = []
    var waiting: CheckedContinuation<WasmRunnerFrame, Error>?
    var dead = false
    var sent: [WasmRunnerFrame] = []
    let respond: (WasmRunnerFrame) -> [WasmRunnerFrame]?   // nil: die
    var pid: pid_t? { lock.withLock { dead ? nil : 4242 } }

    init(respond: @escaping (WasmRunnerFrame) -> [WasmRunnerFrame]?) { self.respond = respond }

    func send(_ frame: WasmRunnerFrame) throws {
        lock.lock()
        if dead { lock.unlock(); throw WasmHost.Failure.crashed }
        sent.append(frame)
        let replies = respond(frame)
        lock.unlock()
        guard let replies else { terminate(); return }
        for reply in replies { deliver(reply) }
    }
    private func deliver(_ frame: WasmRunnerFrame) {
        let waiter: CheckedContinuation<WasmRunnerFrame, Error>? = lock.withLock {
            if let w = waiting { waiting = nil; return w }
            queue.append(frame); return nil
        }
        waiter?.resume(returning: frame)
    }
    func receive() async throws -> WasmRunnerFrame {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<WasmRunnerFrame, Error>? = lock.withLock {
                if !queue.isEmpty { return .success(queue.removeFirst()) }
                if dead { return .failure(WasmHost.Failure.crashed) }
                waiting = continuation; return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }
    func terminate() {
        let waiter: CheckedContinuation<WasmRunnerFrame, Error>? = lock.withLock {
            dead = true; let w = waiting; waiting = nil; return w
        }
        waiter?.resume(throwing: WasmHost.Failure.crashed)
    }
}

final class LaunchCounter: @unchecked Sendable {
    let lock = NSLock(); var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}

final class WasmHostTests: XCTestCase {
    let manifest = ModuleManifest(id: "dev.example.wasm", name: "Example", summary: "", symbol: "cube", version: "1",
                                  capabilities: [Capability(.processesRead)])

    func loaded(_ frame: WasmRunnerFrame, sandboxed: Bool = true) -> WasmRunnerFrame {
        var reply = WasmRunnerFrame(type: "loaded")
        reply.version = WasmRunnerFrame.protocolVersion; reply.exports = ["run"]; reply.sandboxed = true; reply.fileAccessDenied = sandboxed
        return reply
    }

    /// A runner whose `run` asks for `capability` and returns the answer as output (or the refusal code as status).
    func asking(_ capability: String, sandboxed: Bool = true) -> FakeRunner {
        FakeRunner { frame in
            switch frame.type {
            case "load": return [self.loaded(frame, sandboxed: sandboxed)]
            case "call":
                var request = WasmRunnerFrame(type: "request"); request.capability = capability; request.payload = Data(#"{"op":"list"}"#.utf8)
                return [request]
            case "answer":
                var result = WasmRunnerFrame(type: "result"); result.id = 1
                if frame.ok == true { result.status = 0; result.output = frame.data } else { result.status = -1; result.message = frame.outcome }
                return [result]
            default: return []
            }
        }
    }

    func host(_ runner: @escaping @Sendable () -> FakeRunner, limits: WasmHost.Limits = .init(), log: ModuleAccessLog? = nil,
              confirm: @escaping CapabilityBroker.Confirm = { _ in false }, footprint: @escaping @Sendable (pid_t) -> UInt64? = { _ in 1 << 20 },
              home: String = NSTemporaryDirectory()) -> WasmHost {
        let broker = CapabilityBroker(manifest: manifest, home: home, log: log ?? ModuleAccessLog(home: home), handlers: [
            .processesRead: { _ in BrokerAnswer(Data(#"{"processes":[]}"#.utf8)) },
            .filesRead: { _ in XCTFail("an undeclared read must never reach its handler"); return BrokerAnswer(Data()) },
        ], confirm: confirm)
        return WasmHost(manifest: manifest, wasm: Data([0, 97, 115, 109]), broker: broker, limits: limits,
                        launcher: .init { runner() }, supported: true, footprint: footprint)
    }

    func temporaryHome() throws -> String {
        let home = NSTemporaryDirectory() + "thermo-wasm-host-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: home) }
        return home
    }

    func testDeclaredCapabilityIsAnsweredAndUndeclaredIsRefusedAndLogged() async throws {
        let home = try temporaryHome(), log = ModuleAccessLog(home: home)
        let allowed = host({ self.asking("processes.read") }, log: log, home: home)
        let ok = try await allowed.call("run")
        XCTAssertEqual(ok.status, 0); XCTAssertEqual(String(decoding: ok.output, as: UTF8.self), #"{"processes":[]}"#)

        let refused = host({ self.asking("files.read:/etc/hosts") }, log: log, home: home)
        let no = try await refused.call("run")
        XCTAssertEqual(no.status, -1)
        let records = log.records(module: manifest.id)
        XCTAssertEqual(records.map(\.outcome), [.allowed, .denied])
        XCTAssertEqual(records.last?.capability, "files.read")
    }

    func testTimeoutKillsTheRunnerAndTheNextCallStartsAFreshOne() async throws {
        let launches = LaunchCounter()
        let host = host({
            let n = launches.next()
            return FakeRunner { frame in
                if frame.type == "load" { return [self.loaded(frame)] }
                if frame.type == "call", n == 1 { return [] }   // never answers
                var result = WasmRunnerFrame(type: "result"); result.id = frame.id; result.status = 7
                return [result]
            }
        }, limits: .init(callTimeout: 0.2))
        let started = Date()
        do { _ = try await host.call("run"); XCTFail("must time out") } catch { XCTAssertEqual(error as? WasmHost.Failure, .timedOut) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        let again = try await host.call("run")
        XCTAssertEqual(again.status, 7)
        let count = await host.launches
        XCTAssertEqual(count, 2)
    }

    func testTimeWaitingForThePersonDoesNotCount() async throws {
        let slow = FakeRunner { frame in
            switch frame.type {
            case "load": return [self.loaded(frame)]
            case "call": var r = WasmRunnerFrame(type: "request"); r.capability = "processes.end"; r.payload = Data(#"{"targets":[]}"#.utf8); return [r]
            case "answer": var r = WasmRunnerFrame(type: "result"); r.id = 1; r.status = frame.ok == true ? 0 : -2; return [r]
            default: return []
            }
        }
        var m = manifest; m.capabilities.append(Capability(.processesEnd))
        let broker = CapabilityBroker(manifest: m, home: NSTemporaryDirectory(), log: ModuleAccessLog(home: try temporaryHome()),
                                      handlers: [.processesEnd: { _ in BrokerAnswer(Data()) }],
                                      confirm: { _ in try? await Task.sleep(nanoseconds: 600_000_000); return false })
        let confirming = WasmHost(manifest: m, wasm: Data(), broker: broker, limits: .init(callTimeout: 0.2),
                                  launcher: .init { slow }, supported: true, footprint: { _ in 1 })
        let result = try await confirming.call("run")
        XCTAssertEqual(result.status, -2, "declined by the person after 0.6 s, longer than the 0.2 s budget")
    }

    func testFootprintOverTheLimitKillsTheRunner() async throws {
        let host = host({ FakeRunner { frame in frame.type == "load" ? [self.loaded(frame)] : [] } },
                        limits: .init(footprintBytes: 10 << 20, callTimeout: 5), footprint: { _ in 500 << 20 })
        do { _ = try await host.call("run"); XCTFail() } catch { XCTAssertEqual(error as? WasmHost.Failure, .memoryExceeded) }
    }

    func testCrashesAreContainedAndRepeatedFailuresSuspendTheModule() async throws {
        let launches = LaunchCounter()
        let host = host({
            _ = launches.next()
            return FakeRunner { frame in frame.type == "load" ? [self.loaded(frame)] : nil }   // dies on every call
        }, limits: .init(suspendAfter: 3))
        for _ in 0..<3 {
            do { _ = try await host.call("run"); XCTFail() } catch { XCTAssertEqual(error as? WasmHost.Failure, .crashed) }
        }
        do { _ = try await host.call("run"); XCTFail() } catch { XCTAssertEqual(error as? WasmHost.Failure, .suspended) }
        XCTAssertEqual(launches.lock.withLock { launches.count }, 3, "a suspended module is not started again")
        await host.resume()
        do { _ = try await host.call("run"); XCTFail() } catch { XCTAssertEqual(error as? WasmHost.Failure, .crashed) }
    }

    func testTrapsKeepTheRunnerAndSuccessResetsTheCount() async throws {
        let launches = LaunchCounter()
        let host = host({
            _ = launches.next()
            return FakeRunner { frame in
                if frame.type == "load" { return [self.loaded(frame)] }
                var r = WasmRunnerFrame(type: frame.function == "ok" ? "result" : "trap"); r.id = frame.id; r.status = 0
                if frame.function == "fuel" { r.outcome = "outOfFuel" } else { r.message = "unreachable" }
                return [r]
            }
        })
        do { _ = try await host.call("bad"); XCTFail() } catch { XCTAssertEqual(error as? WasmHost.Failure, .trapped("unreachable")) }
        do { _ = try await host.call("fuel"); XCTFail() } catch { XCTAssertEqual(error as? WasmHost.Failure, .outOfFuel) }
        _ = try await host.call("ok")
        let failures = await host.failures
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(launches.lock.withLock { launches.count }, 1)
    }

    func testRefusesARunnerThatDidNotProveItIsSandboxedAndBadModules() async throws {
        let open = host({ self.asking("processes.read", sandboxed: false) })
        do { _ = try await open.call("run"); XCTFail() } catch { XCTAssertEqual(error as? WasmHost.Failure, .notSandboxed) }
        let bad = host({ FakeRunner { _ in var e = WasmRunnerFrame(type: "error"); e.message = "invalid module"; return [e] } })
        do { _ = try await bad.call("run"); XCTFail() } catch { XCTAssertEqual(error as? WasmHost.Failure, .badModule("invalid module")) }
    }

    func testOlderSystemsNeverStartARunner() async throws {
        let broker = CapabilityBroker(manifest: manifest, log: ModuleAccessLog(home: try temporaryHome()), handlers: [:])
        let host = WasmHost(manifest: manifest, wasm: Data(), broker: broker,
                            launcher: .init { XCTFail("no runner on macOS 13/14"); throw WasmHost.Failure.unsupported }, supported: false)
        do { _ = try await host.call("run"); XCTFail() } catch { XCTAssertEqual(error as? WasmHost.Failure, .unsupported) }
    }

    func testFramesRoundTripWithALengthPrefix() throws {
        var frame = WasmRunnerFrame(type: "call"); frame.id = 3; frame.input = Data([1, 2, 3])
        let data = try WasmRunnerFrame.encode(frame)
        let length = data.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        XCTAssertEqual(length, data.count - 4)
        XCTAssertEqual(try JSONDecoder().decode(WasmRunnerFrame.self, from: data.dropFirst(4)), frame)
    }
}
