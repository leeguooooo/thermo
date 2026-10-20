import XCTest
import AgentCore
@testable import ThermoApp

private actor InputReadGate {
    var calls = 0
    var pending: [CheckedContinuation<AudioInputObservation, Never>] = []
    func read() async -> AudioInputObservation {
        calls += 1
        return await withCheckedContinuation { pending.append($0) }
    }
    func finish(_ value: AudioInputObservation) -> Bool {
        guard !pending.isEmpty else { return false }
        pending.removeFirst().resume(returning: value); return true
    }
}

final class MicrophoneAlertsTests: XCTestCase {
    private var ownedSuites: [String] = []
    override func tearDown() {
        for name in ownedSuites { UserDefaults.standard.removePersistentDomain(forName: name) }
        ownedSuites.removeAll()
        super.tearDown()
    }
    @MainActor private func wait(_ check: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 {
            if await check() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("asynchronous microphone state did not settle", file: file, line: line)
    }
    private func fixture() -> UserDefaults {
        let name = "dev.thermo.test.audio-input." + UUID().uuidString
        ownedSuites.append(name)
        return UserDefaults(suiteName: name)!
    }
    private var active: AudioInputObservation {
        .init(clients: [.init(objectID: 1,
            process: .init(pid: 123, uid: 501, started: Date(timeIntervalSince1970: 100), executable: "/Recorder"),
            bundleID: "test.recorder", devices: [.init(id: 2, uid: "built-in", name: "Built-in microphone")])])
    }
    @MainActor func testDisablingAndReenablingCannotPublishOldReadOrStackPhysicalReaders() async {
        let gate = InputReadGate(), defaults = fixture()
        var sent: [AudioInputClient] = []
        let model = MicrophoneAlerts(defaults: defaults, read: { await gate.read() }, send: { sent.append($0) })
        model.poll(); let initially = await gate.calls; XCTAssertEqual(initially, 0)
        model.configure(true, schedule: false)
        await wait { await gate.calls == 1 }
        for _ in 0..<10 { model.poll() }
        model.configure(false); model.configure(true, schedule: false)
        let held = await gate.calls; XCTAssertEqual(held, 1)
        let first = await gate.finish(active); XCTAssertTrue(first)
        await wait { await gate.calls == 2 }
        XCTAssertNil(model.observation); XCTAssertTrue(sent.isEmpty)
        let second = await gate.finish(.init()); XCTAssertTrue(second)
        await wait { model.observation != nil }
        XCTAssertTrue(sent.isEmpty)
        model.poll(); await wait { await gate.calls == 3 }
        let third = await gate.finish(active); XCTAssertTrue(third)
        await wait { sent.count == 1 }
        model.configure(false); XCTAssertNil(model.observation)
    }
    @MainActor func testLateReadAfterDisableStaysQuiet() async {
        let gate = InputReadGate()
        var sent = 0
        let model = MicrophoneAlerts(defaults: fixture(), read: { await gate.read() }, send: { _ in sent += 1 })
        model.configure(true, schedule: false); await wait { await gate.calls == 1 }
        model.configure(false)
        let done = await gate.finish(active); XCTAssertTrue(done)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(model.observation); XCTAssertEqual(sent, 0)
    }
    @MainActor func testMutePersistsAndCanBeRemovedAfterRestart() async {
        let defaults = fixture(), gate = InputReadGate()
        let model = MicrophoneAlerts(defaults: defaults, read: { await gate.read() }, send: { _ in })
        model.setMuted("unknown", true); XCTAssertTrue(model.muted.isEmpty)
        model.configure(true, schedule: false); await wait { await gate.calls == 1 }
        let done = await gate.finish(active); XCTAssertTrue(done)
        await wait { model.observation != nil }
        model.setMuted("test.recorder", true)
        let restored = MicrophoneAlerts(defaults: defaults, send: { _ in })
        XCTAssertEqual(restored.muted, ["test.recorder"])
        XCTAssertEqual(restored.knownApps["test.recorder"], "Recorder")
        restored.setMuted("test.recorder", false)
        XCTAssertTrue(MicrophoneAlerts(defaults: defaults, send: { _ in }).muted.isEmpty)
        model.configure(false)
    }
    @MainActor func testChangesDuringAReadAreCoalescedIntoOneFreshFollowup() async {
        let gate = InputReadGate(), model = MicrophoneAlerts(defaults: fixture(), read: { await gate.read() }, send: { _ in })
        model.configure(true, schedule: false); await wait { await gate.calls == 1 }
        for _ in 0..<20 { model.poll() }
        let first = await gate.finish(.init()); XCTAssertTrue(first)
        await wait { await gate.calls == 2 }
        let second = await gate.finish(active); XCTAssertTrue(second)
        await wait { model.observation?.clients.count == 1 }
        let count = await gate.calls; XCTAssertEqual(count, 2)
        model.configure(false)
    }
    @MainActor func testOwnNotificationMuteWorksAfterRestartWithoutCollectingAHistory() {
        let defaults = fixture(), model = MicrophoneAlerts(defaults: defaults, send: { _ in })
        model.muteFromNotification(key: "test.recorder", name: "Recorder")
        let restored = MicrophoneAlerts(defaults: defaults, send: { _ in })
        XCTAssertEqual(restored.knownApps, ["test.recorder": "Recorder"])
        XCTAssertEqual(restored.muted, ["test.recorder"])
        XCTAssertFalse(defaults.bool(forKey: MicrophoneAlerts.enabledKey))
    }
}
