import XCTest
import AgentCore
@testable import ThermoApp

private actor AudioControlReads {
    var count = 0
    func read() -> AudioInputObservation { count += 1; return .init() }
}

final class AudioInputControlTests: XCTestCase {
    @MainActor func testPreviewAndInvalidRequestsDoNotChangePreferencesOrRequestPermission() async {
        let name = "dev.thermo.test.audio-control." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let reads = AudioControlReads()
        let model = MicrophoneAlerts(defaults: defaults, read: { await reads.read() }, send: { _ in })
        var requests = 0
        let host = AppControlHost(defaults: defaults, audioInput: model,
            configureAudioInput: { model.configure($0, schedule: false) }, requestAudioNotifications: { requests += 1 },
            audioNotificationState: { "allowed" })
        let preview = await host.handle(.init(action: "audio-input.on", dryRun: true))
        XCTAssertTrue(preview.succeeded); XCTAssertEqual(preview.values["changesMade"], "false")
        XCTAssertFalse(defaults.bool(forKey: MicrophoneAlerts.enabledKey)); XCTAssertFalse(model.enabled)
        XCTAssertEqual(requests, 0); XCTAssertEqual(preview.audioInput?.state, "notCollected")
        for request in [AppControlRequest(action: "audio-input.on", arguments: ["app":"unexpected"]),
                        .init(action: "audio-input.mute"), .init(action: "audio-input.mute", arguments: ["app":"unknown"])] {
            let reply = await host.handle(request); XCTAssertFalse(reply.succeeded)
        }
        let count = await reads.count; XCTAssertEqual(count, 0)
    }
    @MainActor func testEnableStatusAndDisableShareTheUIModelWithoutStartingRecording() async {
        let name = "dev.thermo.test.audio-control." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let reads = AudioControlReads()
        let model = MicrophoneAlerts(defaults: defaults, read: { await reads.read() }, send: { _ in })
        var requests = 0
        let host = AppControlHost(defaults: defaults, audioInput: model,
            configureAudioInput: { model.configure($0, schedule: false) }, requestAudioNotifications: { requests += 1 },
            audioNotificationState: { "allowed" })
        let on = await host.handle(.init(action: "audio-input.on"))
        XCTAssertTrue(on.succeeded); XCTAssertTrue(model.enabled); XCTAssertEqual(requests, 1)
        XCTAssertTrue(defaults.bool(forKey: MicrophoneAlerts.enabledKey))
        for _ in 0..<1000 {
            if model.observation != nil { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let status = await host.handle(.init(action: "audio-input.status"))
        XCTAssertEqual(status.audioInput?.state, "idle"); XCTAssertEqual(status.audioInput?.recordsAudio, false)
        XCTAssertEqual(status.audioInput?.notificationAccess, "allowed")
        let count = await reads.count; XCTAssertEqual(count, 1, "status does not start another physical read")
        let off = await host.handle(.init(action: "audio-input.off"))
        XCTAssertTrue(off.succeeded); XCTAssertFalse(model.enabled); XCTAssertEqual(off.audioInput?.state, "notCollected")
        XCTAssertFalse(defaults.bool(forKey: MicrophoneAlerts.enabledKey)); XCTAssertEqual(requests, 1)
    }
    @MainActor func testMuteAndUnmuteArePreviewableAndReplayIsNotAppliedTwice() async {
        let name = "dev.thermo.test.audio-control." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = MicrophoneAlerts(defaults: defaults, send: { _ in })
        model.muteFromNotification(key: "test.recorder", name: "Recorder"); model.setMuted("test.recorder", false)
        let host = AppControlHost(defaults: defaults, audioInput: model, requestAudioNotifications: {}, audioNotificationState: { "allowed" })
        let preview = await host.handle(.init(action: "audio-input.mute", arguments: ["app":"test.recorder"], dryRun: true))
        XCTAssertTrue(preview.succeeded); XCTAssertTrue(model.muted.isEmpty)
        let request = AppControlRequest(action: "audio-input.mute", arguments: ["app":"test.recorder"])
        let muted = await host.handle(request)
        XCTAssertTrue(muted.succeeded); XCTAssertEqual(muted.audioInput?.mutedApps.first?.key, "test.recorder")
        let replay = await host.handle(request); XCTAssertFalse(replay.succeeded)
        let unmuted = await host.handle(.init(action: "audio-input.unmute", arguments: ["app":"test.recorder"]))
        XCTAssertTrue(unmuted.succeeded); XCTAssertTrue(model.muted.isEmpty)
    }
}

extension AudioInputControlTests {
    @MainActor func testActualPrivateSocketReturnsTypedStatusWithoutEnablingObservation() async throws {
        let name = "dev.thermo.test.audio-control." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let directory = URL(fileURLWithPath: "/private/tmp/tai-" + String(UUID().uuidString.prefix(8)))
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: directory) }
        let model = MicrophoneAlerts(defaults: defaults, send: { _ in })
        let host = AppControlHost(defaults: defaults, audioInput: model, requestAudioNotifications: {}, audioNotificationState: { "allowed" })
        let server = try AppControlServer(directory: directory) { request, reply in
            Task { @MainActor in reply(await host.handle(request)) }
        }
        let reply = try await Task.detached {
            try AppControlTransport.request(.init(action: "audio-input.status"), directory: directory)
        }.value
        withExtendedLifetime(server) {
            XCTAssertTrue(reply.succeeded); XCTAssertEqual(reply.audioInput?.enabled, false)
            XCTAssertEqual(reply.audioInput?.state, "notCollected"); XCTAssertNil(reply.audioInput?.complete)
            XCTAssertFalse(model.enabled)
        }
    }
}
