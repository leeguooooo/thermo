import XCTest
import AgentCore
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
    @MainActor func testPreviewDoesNotChangeLoginOrScreen() async {
        let host = AppControlHost(), before = CleanScreenModel.shared.active
        let result = await host.handle(.init(action:"login.on",dryRun:true))
        XCTAssertTrue(result.succeeded); XCTAssertEqual(result.values["changesMade"],"false")
        XCTAssertEqual(CleanScreenModel.shared.active,before)
        let invalid = await host.handle(.init(action:"screen.start",arguments:["duration":"invalid"],dryRun:true))
        XCTAssertFalse(invalid.succeeded)
    }
}

extension AppControlHostTests {
    @MainActor func testActualSocketDispatchesToHostAndAcknowledgesPreview() async throws {
        let root = URL(fileURLWithPath:"/private/tmp/tch-" + String(UUID().uuidString.prefix(8)))
        defer { try? FileManager.default.removeItem(at:root) }
        let host = AppControlHost()
        let server = try AppControlServer(directory:root) { request, reply in
            Task { @MainActor in reply(await host.handle(request)) }
        }
        let response = try await Task.detached {
            try AppControlTransport.request(.init(action:"screen.start",arguments:["duration":"oneMinute"],dryRun:true),directory:root)
        }.value
        withExtendedLifetime(server) {
            XCTAssertTrue(response.succeeded)
            XCTAssertEqual(response.values["changesMade"],"false")
            XCTAssertFalse(CleanScreenModel.shared.active)
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
