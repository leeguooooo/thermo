import XCTest
import ModuleKit
@testable import ModuleHost

final class BrokerTests: XCTestCase {
    var home: URL!
    var log: ModuleAccessLog!
    let id = "dev.thermo.disk"

    override func setUpWithError() throws {
        // Resolved, so paths in assertions equal what the broker acts on (/var is a link on macOS).
        let base = URL(fileURLWithPath: CapabilityBroker.resolved(FileManager.default.temporaryDirectory.path))
        home = base.appendingPathComponent("thermo-broker-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Caches/app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 5000).write(to: home.appendingPathComponent("Library/Caches/app/blob"))
        try Data("secret".utf8).write(to: home.appendingPathComponent("Documents/private.txt"))
        log = ModuleAccessLog(home: home.path)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: home) }

    final class Asked: @unchecked Sendable { var requests: [BrokerRequest] = []; var answer = true }

    func broker(_ capabilities: [String], asked: Asked = Asked(), handlers: [Capability.Kind: CapabilityBroker.Handler]? = nil) -> CapabilityBroker {
        let manifest = ModuleManifest(id: id, name: "Disk", summary: "Cleans.", symbol: "internaldrive", version: "1.0.0",
                                      capabilities: capabilities.map { Capability($0)! })
        XCTAssertEqual(manifest.problems(), [])
        return CapabilityBroker(manifest: manifest, home: home.path, log: log,
                                handlers: handlers ?? [.filesRead: KernelServices.filesRead, .filesDelete: KernelServices.filesDelete],
                                confirm: { request in asked.requests.append(request); return asked.answer })
    }

    func json(_ result: Result<Data, BrokerError>) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: result.get()) as? [String: Any])
    }
    func payload(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
    func denied(_ result: Result<Data, BrokerError>, _ fragment: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case let .failure(error) = result else { return XCTFail("was allowed", file: file, line: line) }
        XCTAssertEqual(error.outcome, .denied, file: file, line: line)
        XCTAssertTrue(error.message.contains(fragment), error.message, file: file, line: line)
    }

    func testDeclaredReadsWorkAndAreLogged() async throws {
        let b = broker(["files.read:~/Library/Caches"])
        let listed = try json(await b.request("files.read:~/Library/Caches/app", payload: payload(["op": "list"])))
        let entries = try XCTUnwrap(listed["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.map { $0["name"] as? String }, ["blob"])
        XCTAssertEqual(entries[0]["kind"] as? String, "file")

        let measured = try json(await b.request("files.read", payload: payload(["op": "measure", "targets": ["~/Library/Caches"]])))
        let result = try XCTUnwrap((measured["results"] as? [[String: Any]])?.first)
        XCTAssertGreaterThanOrEqual(result["bytes"] as? Int ?? 0, 5000)
        XCTAssertEqual(result["complete"] as? Bool, true)

        let read = try json(await b.request("files.read:~/Library/Caches/app/blob", payload: payload(["op": "read"])))
        XCTAssertEqual(Data(base64Encoded: read["base64"] as? String ?? "")?.count, 5000)

        let records = log.records(module: id)
        XCTAssertEqual(records.map(\.outcome), [.allowed, .allowed, .allowed])
        XCTAssertEqual(records.map(\.operation), ["list", "measure", "read"])
        XCTAssertEqual(log.summary(module: id).read, [home.path + "/Library/Caches/app", home.path + "/Library/Caches", home.path + "/Library/Caches/app/blob"])
    }

    func testWhatTheManifestDoesNotCoverIsDeniedAndLogged() async {
        let b = broker(["files.read:~/Library/Caches"])
        denied(await b.request("files.read:~/Documents/private.txt", payload: payload(["op": "read"])), "did not declare files.read")
        denied(await b.request("files.read:~/Library/Caches/../../Documents/private.txt", payload: payload(["op": "read"])), "may not contain ..")
        denied(await b.request("files.read:Library/Caches", payload: payload(["op": "list"])), "must be absolute")
        denied(await b.request("files.delete:~/Library/Caches/app/blob", payload: payload(["op": "trash"])), "did not declare files.delete")
        denied(await b.request("processes.end", payload: Data()), "did not declare processes.end")
        denied(await b.request("root.shell", payload: Data()), "unknown capability")
        denied(await b.request("files.read", payload: payload(["op": "list"])), "needs a target")
        denied(await b.request("files.read:~/Library/Caches", payload: Data("[1]".utf8)), "not a JSON object")
        // One target outside the grant refuses the whole request.
        denied(await b.request("files.read", payload: payload(["op": "measure", "targets": ["~/Library/Caches/app", "~/Documents"]])), "did not declare")
        let records = log.records(module: id)
        XCTAssertEqual(records.count, 9)
        XCTAssertTrue(records.allSatisfy { $0.outcome == .denied && $0.detail != nil })
        XCTAssertEqual(log.summary(module: id).denied, 9)
        XCTAssertTrue(log.summary(module: id).read.isEmpty)
    }

    func testALinkInsideTheGrantDoesNotLeadOutOfIt() async throws {
        try FileManager.default.createSymbolicLink(atPath: home.path + "/Library/Caches/app/escape", withDestinationPath: home.path + "/Documents")
        let b = broker(["files.read:~/Library/Caches", "files.delete:~/Library/Caches"])
        denied(await b.request("files.read:~/Library/Caches/app/escape/private.txt", payload: payload(["op": "read"])), "did not declare files.read")
        denied(await b.request("files.read:~/Library/Caches/app/escape", payload: payload(["op": "list"])), "did not declare files.read")
        denied(await b.request("files.delete:~/Library/Caches/app/escape/private.txt", payload: payload(["op": "trash"])), "did not declare files.delete")
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.path + "/Documents/private.txt"))
    }

    func testDeletingAsksFirstMovesToTheTrashAndNeverTakesTheGrantedFolderItself() async throws {
        let asked = Asked()
        let b = broker(["files.delete:~/Library/Caches"], asked: asked)
        let blob = home.path + "/Library/Caches/app/blob"

        asked.answer = false
        guard case let .failure(no) = await b.request("files.delete:" + blob, payload: payload(["op": "trash"])) else { return XCTFail("deleted without a yes") }
        XCTAssertEqual(no.outcome, .declined)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blob))
        XCTAssertEqual(asked.requests.last?.targets, [blob])

        denied(await b.request("files.delete:~/Library/Caches", payload: payload(["op": "trash"])), "did not declare files.delete")
        XCTAssertEqual(asked.requests.count, 1, "a denied request never reaches the person")

        asked.answer = true
        let done = try json(await b.request("files.delete", payload: payload(["op": "trash", "targets": [blob, home.path + "/Library/Caches/app/gone"]])))
        let results = try XCTUnwrap(done["results"] as? [[String: Any]])
        XCTAssertEqual(results.map { $0["status"] as? String }, ["done", "skipped"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: blob))
        if let trashed = results[0]["trashed"] as? String { try? FileManager.default.removeItem(atPath: trashed) }

        let summary = log.summary(module: id)
        XCTAssertEqual(summary.deleted, [blob], "only what went to the Trash counts as deleted")
        XCTAssertEqual(summary.declined, 1)
        XCTAssertEqual(summary.denied, 1)
    }

    func testAKernelRuleRefusesBeforeThePersonIsAsked() async {
        let asked = Asked()
        let manifest = ModuleManifest(id: id, name: "Disk", summary: "Cleans.", symbol: "internaldrive", version: "1.0.0",
                                      capabilities: [Capability("processes.end")!])
        let ran = Asked()
        let b = CapabilityBroker(manifest: manifest, home: home.path, log: log,
                                 handlers: [.processesEnd: { request in ran.requests.append(request); return BrokerAnswer(Data("{}".utf8), acted: ["node · PID 42"]) }],
                                 rules: [.processesEnd: { request in if request.payload["protected"]?.bool == true { throw BrokerError(.denied, "protected process") } }],
                                 confirm: { request in asked.requests.append(request); return true })
        denied(await b.request("processes.end", payload: payload(["op": "end", "protected": true])), "protected process")
        XCTAssertTrue(asked.requests.isEmpty && ran.requests.isEmpty)
        guard case .success = await b.request("processes.end", payload: payload(["op": "end"])) else { return XCTFail("refused") }
        XCTAssertEqual(asked.requests.count, 1)
        // The log names what the service says it ended.
        XCTAssertEqual(log.summary(module: id).ended, ["node · PID 42"])
        XCTAssertEqual(log.summary(module: id).denied, 1)
    }

    func testADeclaredCapabilityWithoutAKernelServiceFailsAndIsLogged() async {
        let b = broker(["sensors.read"])
        guard case let .failure(error) = await b.request("sensors.read", payload: Data()) else { return XCTFail("answered") }
        XCTAssertEqual(error.outcome, .failed)
        XCTAssertEqual(log.records(module: id).map(\.outcome), [.failed])
    }

    func testNetworkHostsAreCheckedBeforeAnythingIsSent() async {
        let sent = Asked()
        let b = broker(["network.connect:*.example.com"], handlers: [.networkConnect: { request in sent.requests.append(request); return BrokerAnswer(Data("{}".utf8)) }])
        denied(await b.request("network.connect:evil.test", payload: payload(["op": "fetch", "url": "https://evil.test/"])), "did not declare network.connect:evil.test")
        denied(await b.request("network.connect:example.com", payload: payload(["op": "fetch", "url": "https://example.com/"])), "did not declare")
        XCTAssertTrue(sent.requests.isEmpty)
        guard case .success = await b.request("network.connect:API.Example.com", payload: payload(["op": "fetch", "url": "https://api.example.com/v1"])) else { return XCTFail("refused") }
        XCTAssertEqual(sent.requests.first?.targets, ["api.example.com"])
        XCTAssertEqual(log.summary(module: id).hosts, ["api.example.com"])

        // The real service refuses a URL that goes somewhere else than the host that was checked.
        let real = broker(["network.connect:api.example.com"], handlers: [.networkConnect: KernelServices.networkConnect()])
        denied(await real.request("network.connect:api.example.com", payload: payload(["op": "fetch", "url": "https://evil.test/"])), "goes to evil.test")
        guard case let .failure(plain) = await real.request("network.connect:api.example.com", payload: payload(["op": "fetch", "url": "http://api.example.com/"])) else { return XCTFail("sent over http") }
        XCTAssertEqual(plain.outcome, .failed)
    }

    func testTheLogRotatesAndIgnoresBadModuleNames() {
        log.record(.init(module: "../../evil", capability: "files.read", outcome: .allowed))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path + "/Library/Application Support/Thermo/evil"))
        let targets = (0..<200).map { "/tmp/" + String(repeating: "x", count: 200) + "\($0)" }
        let one = ModuleAccessRecord(module: id, capability: "files.read", operation: "measure", targets: targets, outcome: .allowed)
        XCTAssertEqual(one.targets.count, ModuleAccessLog.listedTargets)
        XCTAssertEqual(one.targetCount, 200)
        for _ in 0..<400 { log.record(one) }
        let folder = log.url(module: id).deletingLastPathComponent()
        let size = { (name: String) in ((try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path))?[.size] as? Int) ?? 0 }
        XCTAssertGreaterThan(size("access.1.jsonl"), 0)
        XCTAssertLessThanOrEqual(size("access.jsonl"), ModuleAccessLog.maxBytes)
        XCTAssertLessThanOrEqual(size("access.1.jsonl"), ModuleAccessLog.maxBytes)
        XCTAssertGreaterThan(log.records(module: id).count, 100)
    }
}
