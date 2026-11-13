import AgentCore
import ModuleHost
import ModuleKit
import ThermoL10n
import XCTest
@testable import ThermoApp

@MainActor final class ModuleCenterTests: XCTestCase {
    func testPageArgumentNamesAModuleAndOptionallyItsEntry() {
        XCTAssertEqual(MainPage(argument: "module:dev.thermo.disk"), .module("dev.thermo.disk", ""))
        XCTAssertEqual(MainPage(argument: "module:dev.thermo.disk:scan"), .module("dev.thermo.disk", "scan"))
        XCTAssertNil(MainPage(argument: "module"))
    }

    func testAnAppWithoutModulesShowsNoneAndStartsNothing() async {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-none-" + UUID().uuidString + "/Thermo.app")
        let name = "thermo-module-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let center = ModuleCenter(manager: ModuleManager(app: empty), defaults: defaults)
        center.start()
        for _ in 0..<100 where !center.loaded { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(center.loaded)
        XCTAssertTrue(center.statuses.isEmpty && center.pages.isEmpty)
        XCTAssertNil(center.page(module: "dev.thermo.disk", entry: ""))
        // Switching an unknown module only records the choice.
        center.setEnabled("dev.thermo.disk", true)
        XCTAssertEqual(defaults.object(forKey: ModuleCenter.key("dev.thermo.disk")) as? Bool, true)
        XCTAssertTrue(center.pages.isEmpty)
    }
}

@MainActor final class ModuleKernelTests: XCTestCase {
    func request(_ kind: Capability.Kind, payload: [String: JSONValue] = [:], targets: [String] = []) -> BrokerRequest {
        let manifest = ModuleManifest(id: "dev.thermo.disk", name: "Disk Cleanup", summary: "Cleans.", symbol: "internaldrive", version: "1.0.0")
        return BrokerRequest(manifest: manifest, kind: kind, operation: kind == .processesEnd ? "end" : "trash", targets: targets, payload: payload)
    }

    final class Asked: @unchecked Sendable { var count = 0 }
    func broker(_ capabilities: [String], asked: Asked, log: ModuleAccessLog) -> CapabilityBroker {
        let manifest = ModuleManifest(id: "dev.thermo.disk", name: "Disk Cleanup", summary: "Cleans.", symbol: "internaldrive", version: "1.0.0",
                                      capabilities: capabilities.map { Capability($0)! })
        return ModuleKernel.broker(for: manifest, log: log, confirm: { _ in asked.count += 1; return true })
    }
    func scratchLog() -> (ModuleAccessLog, URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-kernel-" + UUID().uuidString)
        return (ModuleAccessLog(home: home.path), home)
    }
    func processes(_ pids: [Int32], started: Double? = nil) -> Data {
        let named: [[String: Any]] = pids.compactMap { pid in
            ProcessTable.identity(pid).map { ["pid": Int(pid), "started": started ?? $0.started.timeIntervalSince1970] }
        }
        return try! JSONSerialization.data(withJSONObject: ["op": "end", "processes": named])
    }

    func testThermoItselfAndSystemProcessesAreRefusedBeforeAnyoneIsAsked() async {
        let (log, home) = scratchLog(); defer { try? FileManager.default.removeItem(at: home) }
        let asked = Asked()
        let b = broker(["processes.end"], asked: asked, log: log)
        // One protected process in a request refuses all of it, the unprotected parent included.
        for pids in [[getpid()], [getppid(), getpid()]] {
            guard case let .failure(error) = await b.request("processes.end", payload: processes(pids)) else { return XCTFail("ended \(pids)") }
            XCTAssertEqual(error.outcome, .denied, error.message)
        }
        // launchd cannot even be identified by an unprivileged process: the request names nothing.
        guard case .failure = await b.request("processes.end", payload: processes([1])) else { return XCTFail("ended launchd") }
        XCTAssertNotNil(ProcessTable.identity(getppid()))
        XCTAssertEqual(asked.count, 0, "nobody is asked to end what Thermo never ends")
        XCTAssertNotNil(ProcessTable.identity(getpid()))
        XCTAssertEqual(log.summary(module: "dev.thermo.disk").denied, 2)
        XCTAssertTrue(log.summary(module: "dev.thermo.disk").ended.isEmpty)
    }

    func testThermosOwnHelpersAndModulesCountAsThermo() {
        let bundle = Bundle.main.bundleURL.path
        XCTAssertTrue(ModuleKernel.ownProcess(bundle + "/Contents/Extensions/Disk.appex/Contents/MacOS/Disk"))
        XCTAssertTrue(ModuleKernel.ownProcess(bundle + "/Contents/Helpers/thermo-helper"))
        XCTAssertFalse(ModuleKernel.ownProcess("/opt/homebrew/bin/node"))
        XCTAssertFalse(ModuleKernel.ownProcess(nil))
    }

    func testAReusedPIDIsNotEnded() async throws {
        let (log, home) = scratchLog(); defer { try? FileManager.default.removeItem(at: home) }
        let asked = Asked()
        let b = broker(["processes.end"], asked: asked, log: log)
        let data = try await b.request("processes.end", payload: processes([getpid()], started: 12345)).get()
        let results = try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [String: Any])?["results"] as? [[String: Any]])
        XCTAssertEqual(results.map { $0["outcome"] as? String }, ["changed"])
        XCTAssertTrue(log.summary(module: "dev.thermo.disk").ended.isEmpty)
    }

    func testProtectedPlacesStayClosedToAModuleThatDeclaredThem() async {
        let (log, home) = scratchLog(); defer { try? FileManager.default.removeItem(at: home) }
        let asked = Asked()
        // The manifest is valid and covers these; Thermo's own protection still refuses them.
        let b = broker(["files.delete:~/Documents", "files.delete:~/.ssh", "files.delete:~/Library"], asked: asked, log: log)
        for path in ["~/Documents/thermo-test-missing.txt", "~/.ssh/thermo-test-missing", "~/Library/Caches"] {
            guard case let .failure(error) = await b.request("files.delete:" + path, payload: Data(#"{"op":"trash"}"#.utf8)) else { return XCTFail("deleted \(path)") }
            XCTAssertEqual(error.outcome, .denied, error.message)
            XCTAssertTrue(error.message.contains("is protected"), error.message)
        }
        XCTAssertEqual(asked.count, 0)
    }

    func testTheConfirmationIsBuiltFromTheCheckedRequest() {
        L10n.override = .english
        defer { L10n.override = nil }
        let names = (1...11).map { "/Users/x/Library/Caches/item\($0)" }
        let text = ModuleKernel.confirmation(request(.filesDelete, targets: names), names: names)
        XCTAssertEqual(text.title, "Disk Cleanup wants to move 11 items to the Trash")
        XCTAssertTrue(text.detail.contains("item8") && !text.detail.contains("item9") && text.detail.contains("3 more"), text.detail)
        XCTAssertEqual(text.action, "Move to Trash")
    }
}
