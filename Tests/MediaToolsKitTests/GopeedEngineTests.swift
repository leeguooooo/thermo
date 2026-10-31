import XCTest
@testable import MediaToolsKit

final class GopeedEngineTests: XCTestCase {
    private func make(installed: Bool = true, ready: Bool = true, readyTimeout: TimeInterval = 2) throws -> (GopeedEngine, FakeTransport, FakeLauncher, MediaToolsRoot) {
        let root = try makeRoot()
        if installed { try writeFakeBinary(root.gopeedExecutable) }
        let transport = FakeTransport()
        let launcher = FakeLauncher()
        if ready { transport.on("GET /api/v1/info", json: ["code": 0, "data": ["version": "1.9.3"]]) }
        let engine = GopeedEngine(root: root, transport: transport, launcher: launcher, runner: FakeRunner(), readyTimeout: readyTimeout, stopTimeout: 0.1)
        return (engine, transport, launcher, root)
    }

    private func body(_ request: MediaRequest?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request?.body)) as? [String: Any])
    }

    func testResolveListsFilesAndSelectionTravelsWithTheRequestNotAResolveID() async throws {
        let (engine, transport, _, _) = try make()
        _ = try await engine.start()
        transport.on("POST /api/v1/resolve", json: ["code": 0, "data": ["id": "r1", "res": [
            "name": "pack", "files": [["name": "a.mkv", "path": "", "size": 5], ["name": "b.mkv", "path": "sub", "size": 7]],
        ]]])
        transport.on("POST /api/v1/tasks", json: ["code": 0, "data": "t1"])
        let resolved = try await engine.resolve(url: "magnet:?xt=urn:btih:0")
        XCTAssertEqual(resolved.files.map(\.displayPath), ["a.mkv", "sub/b.mkv"])
        XCTAssertEqual(resolved.files.last?.size, 7)
        XCTAssertEqual((try body(transport.requests("POST", "/api/v1/resolve").first))["req"] as? [String: String], ["url": "magnet:?xt=urn:btih:0"])
        _ = try await engine.createTask(url: "magnet:?xt=urn:btih:0", saveDir: "/d", fileName: "", selectFiles: [1])
        let sent = try body(transport.requests("POST", "/api/v1/tasks").first)
        XCTAssertNil(sent["rid"])
        XCTAssertEqual((sent["opts"] as? [String: Any])?["selectFiles"] as? [Int], [1])
        await engine.stop()
    }

    func testStartPassesOnlySupportedFlagsAndIsIdempotent() async throws {
        let (engine, _, launcher, root) = try make()
        let port = try await engine.start()
        XCTAssertEqual(port, 53111)
        XCTAssertEqual(launcher.launches.first?.1, ["-A", "127.0.0.1", "-P", "53111", "-d", root.gopeedStorage.path])
        XCTAssertEqual(launcher.launches.first?.0, root.gopeedExecutable)
        _ = try await engine.start()
        XCTAssertEqual(launcher.launches.count, 1)
        let version = await engine.version()
        XCTAssertEqual(version, "1.9.3")
        XCTAssertEqual(try String(contentsOf: root.gopeedPIDFile, encoding: .utf8), "4242")
        let mode = try FileManager.default.attributesOfItem(atPath: root.gopeedStorage.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
    }

    func testEveryRequestCarriesAFreshTokenThatStaysOutOfArgv() async throws {
        let (engine, transport, launcher, _) = try make()
        try await engine.start()
        let first = try XCTUnwrap(launcher.environments.last?[GopeedEngine.apiTokenVariable])
        XCTAssertEqual(first.count, 64)
        XCTAssertFalse(launcher.launches[0].1.contains(first))
        XCTAssertFalse(transport.sent.isEmpty)
        XCTAssertTrue(transport.sent.allSatisfy { $0.headers[GopeedEngine.apiTokenHeader] == first })

        let (other, _, otherLauncher, _) = try make()
        try await other.start()
        XCTAssertNotEqual(otherLauncher.environments.last?[GopeedEngine.apiTokenVariable], first)
    }

    func testStartWithoutKernelNeverLaunches() async throws {
        let (engine, _, launcher, _) = try make(installed: false)
        do {
            try await engine.start()
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? GopeedError, .notInstalled)
        }
        XCTAssertTrue(launcher.launches.isEmpty)
    }

    func testEarlyExitIsReportedAsExitNotTimeout() async throws {
        let (engine, _, launcher, _) = try make(ready: false)
        launcher.process.exit(2)
        do {
            try await engine.start()
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? GopeedError, .startFailed(exitCode: 2))
        }
        let port = await engine.port
        XCTAssertEqual(port, 0)
    }

    func testReadyTimeoutKillsChild() async throws {
        let (engine, _, launcher, _) = try make(ready: false, readyTimeout: 0.1)
        do {
            try await engine.start()
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? GopeedError, .startFailed(exitCode: nil))
        }
        XCTAssertEqual(launcher.process.killed, 1)
    }

    func testStopEscalatesToKill() async throws {
        let (engine, _, launcher, root) = try make()
        try await engine.start()
        launcher.process.ignoresTerminate = true
        await engine.stop()
        XCTAssertEqual(launcher.process.terminated, 1)
        XCTAssertEqual(launcher.process.killed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.gopeedPIDFile.path))
        let state = await engine.state
        XCTAssertEqual(state, .installed)
    }

    func testStaleProcessKilledOnlyWhenItIsOurKernel() async throws {
        let (engine, _, launcher, root) = try make()
        try FileManager.default.createDirectory(at: root.gopeedDir, withIntermediateDirectories: true)
        try "777".write(to: root.gopeedPIDFile, atomically: true, encoding: .utf8)
        launcher.paths[777] = root.gopeedExecutable.path
        try await engine.start()
        XCTAssertEqual(launcher.killed, [777])

        let (other, _, otherLauncher, otherRoot) = try make()
        try FileManager.default.createDirectory(at: otherRoot.gopeedDir, withIntermediateDirectories: true)
        try "777".write(to: otherRoot.gopeedPIDFile, atomically: true, encoding: .utf8)
        otherLauncher.paths[777] = "/Applications/Gopeed.app/Contents/MacOS/gopeed"
        try await other.start()
        XCTAssertTrue(otherLauncher.killed.isEmpty)
    }

    func testCreateTaskBodyMatchesGopeed() async throws {
        let (engine, transport, _, _) = try make()
        transport.on("POST /api/v1/tasks", json: ["code": 0, "data": " abc "])
        try await engine.start()
        let id = try await engine.createTask(
            url: "https://x.test/f", saveDir: "/tmp/d", fileName: "f.bin", headers: ["Cookie": "c"], connections: 8, label: "L", trackers: ["udp://t"])
        XCTAssertEqual(id, "abc")
        let json = try body(transport.requests("POST", "/api/v1/tasks").first)
        let request = try XCTUnwrap(json["req"] as? [String: Any])
        XCTAssertEqual(request["url"] as? String, "https://x.test/f")
        XCTAssertEqual((request["extra"] as? [String: Any])?["header"] as? [String: String], ["Cookie": "c"])
        XCTAssertEqual((request["extra"] as? [String: Any])?["trackers"] as? [String], ["udp://t"])
        XCTAssertEqual(request["labels"] as? [String: String], ["thermoTaskId": "L"])
        let options = try XCTUnwrap(json["opts"] as? [String: Any])
        XCTAssertEqual(options["path"] as? String, "/tmp/d")
        XCTAssertEqual(options["name"] as? String, "f.bin")
        XCTAssertEqual((options["extra"] as? [String: Any])?["connections"] as? Int, 8)
    }

    func testMagnetTaskOmitsEmptyFields() async throws {
        let (engine, transport, _, _) = try make()
        transport.on("POST /api/v1/tasks", json: ["code": 0, "data": "id"])
        try await engine.start()
        _ = try await engine.createTask(url: "magnet:?xt=1", saveDir: "/d", fileName: "")
        let json = try body(transport.requests("POST", "/api/v1/tasks").first)
        XCTAssertNil((json["req"] as? [String: Any])?["extra"])
        XCTAssertNil((json["opts"] as? [String: Any])?["name"])
    }

    func testStatusReadsTaskObject() async throws {
        let (engine, transport, _, _) = try make()
        transport.on("GET /api/v1/tasks/t1", json: ["code": 0, "data": [
            "id": "t1", "status": "running", "progress": ["downloaded": 5, "speed": 2],
            "meta": ["res": ["name": "seed", "size": 9, "files": [["path": "sub"], ["path": ""]]]],
        ]])
        try await engine.start()
        let view = try await engine.taskStatus("t1")
        XCTAssertEqual(view, GopeedTaskView(id: "t1", status: "running", downloaded: 5, total: 9, speed: 2))
        let detail = try await engine.taskDetail("t1")
        XCTAssertEqual(detail, GopeedTaskDetail(name: "seed", fileCount: 2, folder: true))
    }

    func testTaskErrorNeverFallsBackToFullTaskJSON() async throws {
        let (engine, transport, _, _) = try make()
        transport.on("GET /api/v1/tasks/a", json: ["code": 0, "data": ["meta": ["req": ["url": "https://x.test/f?token=s3cret", "extra": ["header": ["Cookie": "c"]]]]]])
        transport.on("GET /api/v1/tasks/b", json: ["code": 0, "data": ["error": "fetch https://x.test/f?token=s3cret failed"]])
        try await engine.start()
        let none = await engine.taskError("a")
        XCTAssertNil(none)
        let message = await engine.taskError("b")
        XCTAssertEqual(message, "fetch https://x.test/f failed")
    }

    func testEnvelopeErrorsAreRedacted() async throws {
        let (engine, transport, _, _) = try make()
        transport.on("PUT /api/v1/tasks/x/pause", json: ["code": 1000, "msg": "bad https://x.test/f?sig=abc"])
        transport.on("GET /api/v1/tasks/y", .init(status: 500, body: Data("token=s3cret".utf8)))
        try await engine.start()
        do {
            try await engine.pauseTask("x")
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? GopeedError, .api("bad https://x.test/f"))
        }
        do {
            _ = try await engine.taskStatus("y")
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? GopeedError, .invalidResponse)
        }
    }

    func testStatsVariants() async throws {
        let (engine, transport, _, _) = try make()
        transport.on("GET /api/v1/tasks/bt/stats", json: ["code": 0, "data": ["runtime": ["activePeers": 3, "totalPeers": 9, "connectedSeeders": 1]]])
        transport.on("GET /api/v1/tasks/ed/stats", json: ["code": 0, "data": ["runtime": ["activePeers": 3, "totalPeers": 9]]])
        transport.on("GET /api/v1/tasks/http/stats", json: ["code": 0, "data": ["snapshot": ["connections": [1, 2]]]])
        try await engine.start()
        var peers = await engine.taskPeerInfo("bt")
        XCTAssertEqual(peers, GopeedPeerInfo(seeds: 1, peers: 3, total: 9))
        peers = await engine.taskPeerInfo("ed")
        XCTAssertEqual(peers, GopeedPeerInfo(seeds: -1, peers: 3, total: 9))
        peers = await engine.taskPeerInfo("http")
        XCTAssertNil(peers)
        let connections = await engine.taskConnections("http")
        XCTAssertEqual(connections, 2)
    }

    func testTaskIDIsEscapedIntoPath() async throws {
        let (engine, transport, _, _) = try make()
        transport.on("DELETE /api/v1/tasks/a/b", json: ["code": 0])
        try await engine.start()
        _ = try? await engine.deleteTask("a/b")
        XCTAssertTrue(transport.sent.last?.url.absoluteString.contains("a%2Fb") == true)
    }

    func testRuntimeConfigMergesAndWakesOnlyFreeSlots() async throws {
        let (engine, transport, _, _) = try make()
        transport.on("GET /api/v1/config", json: ["code": 0, "data": [
            "downloadDir": "/keep", "protocolConfig": ["bt": ["listenPort": 1], "http": ["userAgent": "mine"]],
        ]])
        transport.on("PUT /api/v1/config", json: ["code": 0])
        transport.on("GET /api/v1/tasks", json: ["code": 0, "data": [
            ["id": "r", "status": "running"], ["id": "w1", "status": "wait"], ["id": "w2", "status": "wait"], ["id": "w3", "status": "wait"],
        ]])
        transport.on("PUT /api/v1/tasks/w1/continue", json: ["code": 0])
        transport.on("PUT /api/v1/tasks/w2/continue", json: ["code": 0])
        try await engine.start()
        let settings = GopeedRuntimeSettings(httpConnections: 900, proxy: .manual(host: "p.test", port: 8080), trackers: ["udp://t"], dhtEnabled: false)
        let applied = try await engine.applyRuntimeConfig(maxRunning: 3, settings: settings)
        XCTAssertEqual(applied, 3)
        let config = try body(transport.requests("PUT", "/api/v1/config").first)
        XCTAssertEqual(config["downloadDir"] as? String, "/keep")
        XCTAssertEqual(config["maxRunning"] as? Int, 3)
        let protocols = try XCTUnwrap(config["protocolConfig"] as? [String: Any])
        let bt = try XCTUnwrap(protocols["bt"] as? [String: Any])
        XCTAssertEqual(bt["listenPort"] as? Int, 1)
        XCTAssertEqual(bt["seedTime"] as? Int, 1)
        XCTAssertEqual(bt["seedKeep"] as? Bool, false)
        XCTAssertEqual(bt["customTrackers"] as? [String], ["udp://t"])
        XCTAssertEqual(bt["disableDht"] as? Bool, true)
        let http = try XCTUnwrap(protocols["http"] as? [String: Any])
        XCTAssertEqual(http["connections"] as? Int, 512)
        XCTAssertEqual(http["userAgent"] as? String, "mine")
        XCTAssertEqual((config["proxy"] as? [String: Any])?["host"] as? String, "p.test:8080")
        XCTAssertEqual(transport.requests("PUT", "/api/v1/tasks/w1/continue").count, 1)
        XCTAssertEqual(transport.requests("PUT", "/api/v1/tasks/w2/continue").count, 1)
        XCTAssertTrue(transport.requests("PUT", "/api/v1/tasks/w3/continue").isEmpty)
    }

    func testRuntimeConfigNoopWhenStopped() async throws {
        let (engine, transport, _, _) = try make()
        let applied = try await engine.applyRuntimeConfig(maxRunning: 3, settings: .init())
        XCTAssertNil(applied)
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testProxyMapping() {
        XCTAssertEqual(GopeedProxy.direct.json["enable"] as? Bool, false)
        XCTAssertEqual(GopeedProxy.system.json["system"] as? Bool, true)
        XCTAssertEqual(GopeedProxy.manual(host: "user:pw@p.test", port: 80).json["enable"] as? Bool, false)
        XCTAssertEqual(GopeedProxy.manual(host: "p.test", port: 0).json["enable"] as? Bool, false)
    }

    func testRealLauncherFindsFreePortAndOwnPath() throws {
        let launcher = SystemGopeedLauncher()
        XCTAssertGreaterThan(try launcher.freePort(), 0)
        XCTAssertNotNil(launcher.executablePath(pid: getpid()))
    }
}
