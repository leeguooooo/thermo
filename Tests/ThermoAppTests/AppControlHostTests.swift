import XCTest
import AgentCore
import ThermoKit
@testable import ThermoApp

final class AppControlHostTests: XCTestCase {
    @MainActor func testUnknownActionAndReplayAreRefused() async {
        let host = AppControlHost()
        let request = AppControlRequest(action:"status")
        let first = await host.handle(request)
        XCTAssertTrue(first.succeeded)
        let replay = await host.handle(request)
        XCTAssertFalse(replay.succeeded)
        let unsupported = await host.handle(.init(action:"shell",arguments:["command":"touch sentinel"]))
        XCTAssertFalse(unsupported.succeeded)
    }
    @MainActor func testPreviewDoesNotStartInputInterception() async {
        let driver = AppControlTestScreenDriver()
        let model = CleanScreenModel(driver:driver)
        let host = AppControlHost(screen:model), before = model.active
        let result = await host.handle(.init(action:"screen.start",dryRun:true))
        XCTAssertTrue(result.succeeded); XCTAssertEqual(result.values["changesMade"],"false")
        XCTAssertEqual(model.active,before)
        XCTAssertEqual(driver.starts,0)
        let invalid = await host.handle(.init(action:"screen.start",arguments:["duration":"invalid"],dryRun:true))
        XCTAssertFalse(invalid.succeeded)
    }
}

extension AppControlHostTests {
    @MainActor func testActualSocketDispatchesToHostAndAcknowledgesPreview() async throws {
        let root = URL(fileURLWithPath:"/private/tmp/tch-" + String(UUID().uuidString.prefix(8)))
        defer { try? FileManager.default.removeItem(at:root) }
        let driver = AppControlTestScreenDriver()
        let model = CleanScreenModel(driver:driver)
        let host = AppControlHost(screen:model)
        let server = try AppControlServer(directory:root) { request, reply in
            Task { @MainActor in reply(await host.handle(request)) }
        }
        let response = try await Task.detached {
            try AppControlTransport.request(.init(action:"screen.start",arguments:["duration":"oneMinute"],dryRun:true),directory:root)
        }.value
        withExtendedLifetime(server) {
            XCTAssertTrue(response.succeeded)
            XCTAssertEqual(response.values["changesMade"],"false")
            XCTAssertFalse(model.active)
            XCTAssertEqual(driver.starts,0)
        }
    }
}

extension AppControlHostTests {
    @MainActor func testScreenDurationPreviewDoesNotWriteAndExplicitSettingPersists() async throws {
        let suite = "thermo.cli.duration." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let host = AppControlHost(defaults:defaults)
        let preview = await host.handle(.init(action:"screen.duration",arguments:["duration":"fiveMinutes"],dryRun:true))
        XCTAssertTrue(preview.succeeded)
        XCTAssertNil(defaults.string(forKey:CleanScreenDuration.preferenceKey))
        let applied = await host.handle(.init(action:"screen.duration",arguments:["duration":"fiveMinutes"]))
        XCTAssertTrue(applied.succeeded)
        XCTAssertEqual(defaults.string(forKey:CleanScreenDuration.preferenceKey),"fiveMinutes")
        XCTAssertEqual(applied.values["savedDuration"],"fiveMinutes")
        XCTAssertFalse(CleanScreenModel.shared.active)
    }
}

extension AppControlHostTests {
    @MainActor func testSignedCompanionCLIReachesHostAndOtherExecutableIsRefused() async throws {
        let root = URL(fileURLWithPath:"/private/tmp/tcs-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:root) }
        let builtCLI = Bundle(for:Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("thermo")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath:builtCLI.path),builtCLI.path)
        let cli = root.appendingPathComponent("thermo")
        try FileManager.default.copyItem(at:builtCLI,to:cli)
        let sign = Process(); sign.executableURL = URL(fileURLWithPath:"/usr/bin/codesign")
        sign.arguments = ["--force","--sign","-","--timestamp=none","--identifier","dev.thermo.cli",cli.path]
        sign.standardOutput = FileHandle.nullDevice; sign.standardError = FileHandle.nullDevice
        try sign.run(); sign.waitUntilExit(); XCTAssertEqual(sign.terminationStatus,0)
        let trust = try LocalControlPeerTrust(team:nil,developmentExecutable:cli)
        let directory = root.appendingPathComponent("Library/Application Support/Thermo/Control")
        let suite = "thermo.signed-peer." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let driver = AppControlTestScreenDriver()
        let model = CleanScreenModel(driver:driver)
        let host = AppControlHost(defaults:defaults,screen:model)
        defer { model.stop() }
        let server = try AppControlServer(directory:directory,authorize:{ trust.accepts(auditToken:$0) }) { request,reply in
            Task { @MainActor in reply(await host.handle(request)) }
        }
        func callCLI(_ arguments: [String]) async throws -> (Int32,Data,Data) {
            try await Task.detached {
            let process = Process(), out = Pipe(), err = Pipe()
            process.executableURL = cli; process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["CFFIXED_USER_HOME"] = root.path; environment["HOME"] = root.path
            process.environment = environment; process.standardOutput = out; process.standardError = err
            try process.run()
            let stdout = out.fileHandleForReading.readDataToEndOfFile(), stderr = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus,stdout,stderr)
            }.value
        }
        let result = try await callCLI(["screen","start","--duration","oneMinute","--yes","--json"])
        XCTAssertEqual(result.0,0,String(decoding:result.2,as:UTF8.self))
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with:result.1) as? [String:Any])
        XCTAssertEqual(value["succeeded"] as? Bool,true)
        XCTAssertTrue(model.active)
        let stopped = try await callCLI(["screen","stop","--yes","--json"])
        XCTAssertEqual(stopped.0,0,String(decoding:stopped.2,as:UTF8.self))
        XCTAssertFalse(model.active)
        let denied = try await Task.detached { try AppControlTransport.request(.init(action:"screen.start"),directory:directory) }.value
        withExtendedLifetime(server) {
            XCTAssertFalse(denied.succeeded)
            XCTAssertTrue(denied.issue?.contains("signature") == true)
            XCTAssertFalse(model.active)
            XCTAssertEqual(driver.starts,1)
            XCTAssertEqual(driver.stops,1)
        }
    }
}

@MainActor private final class AppControlTestScreenDriver: CleanScreenDriver {
    var hasAccessibility = true
    var starts = 0, stops = 0
    func begin(_ model: CleanScreenModel) throws { starts += 1 }
    func end() { stops += 1 }
}
