import XCTest
import AgentCore
@testable import ThermoApp

private actor CameraReadGate {
    var calls = 0
    private var pending: [CheckedContinuation<CameraObservation, Never>] = []
    func read() async -> CameraObservation { calls += 1; return await withCheckedContinuation { pending.append($0) } }
    func finish(_ value: CameraObservation) { pending.removeFirst().resume(returning: value) }
}
final class CameraAlertsTests: XCTestCase {
    @MainActor private func wait(_ check: () async -> Bool) async {
        for _ in 0..<1000 { if await check() { return }; try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTFail("camera observation did not settle")
    }
    @MainActor func testOldReadCannotPublishAfterDisableAndReenableOrStackReaders() async {
        let gate = CameraReadGate(); var sent = 0
        let model = CameraAlerts(read: { await gate.read() }, send: { _ in sent += 1 })
        model.configure(true, schedule: false); await wait { await gate.calls == 1 }
        model.poll(); model.configure(false); model.configure(true, schedule: false)
        let calls = await gate.calls; XCTAssertEqual(calls, 1)
        let active = CameraObservation(devices: [.init(objectID: 1, uid: "camera", name: "Camera", active: true)])
        await gate.finish(active); await wait { await gate.calls == 2 }
        XCTAssertNil(model.observation); XCTAssertEqual(sent, 0)
        await gate.finish(.init()); await wait { model.observation != nil }
        model.poll(); await wait { await gate.calls == 3 }; await gate.finish(active)
        await wait { sent == 1 }; model.configure(false)
    }
    @MainActor func testPreviewRejectAndReplayDoNotMutateRealPreferencesOrRequestPermission() async {
        let suite = "dev.thermo.test.camera." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let model = CameraAlerts(defaults: defaults, read: { .init() }, send: { _ in })
        var requests = 0
        let host = AppControlHost(defaults: defaults, requestAudioNotifications: { requests += 1 }, audioNotificationState: { "denied" },
                                  camera: model, configureCamera: { model.configure($0, schedule: false) })
        let preview = await host.handle(.init(action: "camera.on", dryRun: true))
        XCTAssertTrue(preview.succeeded); XCTAssertEqual(preview.camera?.state, "notCollected")
        XCTAssertFalse(model.enabled); XCTAssertEqual(requests, 0)
        XCTAssertFalse(defaults.bool(forKey: CameraAlerts.enabledKey))
        let invalid = await host.handle(.init(action: "camera.on", arguments: ["app":"not-supported"]))
        XCTAssertFalse(invalid.succeeded); XCTAssertEqual(requests, 0)
        let request = AppControlRequest(action: "camera.on")
        let on = await host.handle(request); XCTAssertTrue(on.succeeded); XCTAssertTrue(model.enabled); XCTAssertEqual(requests, 1)
        await wait { model.observation != nil }
        let status = await host.handle(.init(action: "camera.status"))
        XCTAssertEqual(status.camera?.state, "noDevices"); XCTAssertEqual(status.camera?.notificationAccess, "denied")
        let replay = await host.handle(request); XCTAssertFalse(replay.succeeded); XCTAssertEqual(requests, 1)
        let off = await host.handle(.init(action: "camera.off")); XCTAssertTrue(off.succeeded)
        XCTAssertFalse(model.enabled); XCTAssertNil(model.observation)
        XCTAssertFalse(defaults.bool(forKey: CameraAlerts.enabledKey))
    }
    @MainActor func testDefaultOffAndLateCompletionStayQuiet() async {
        let suite = "dev.thermo.test.camera." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let gate = CameraReadGate(); var sent = 0
        let model = CameraAlerts(defaults: defaults, read: { await gate.read() }, send: { _ in sent += 1 })
        model.start(); model.poll(); let calls = await gate.calls; XCTAssertEqual(calls, 0)
        model.configure(true, schedule: false); await wait { await gate.calls == 1 }
        model.configure(false); await gate.finish(.init(devices: [.init(objectID: 1, uid: "test", name: "Camera", active: true)]))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(model.observation); XCTAssertEqual(sent, 0)
    }
}
