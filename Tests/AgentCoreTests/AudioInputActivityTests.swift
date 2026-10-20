import XCTest
@testable import AgentCore

final class AudioInputActivityTests: XCTestCase {
    private func process(_ pid: Int32 = 42, start: Double = 100) -> ProcessIdentity {
        .init(pid: pid, uid: 501, started: Date(timeIntervalSince1970: start), executable: "/Applications/Recorder.app/Contents/MacOS/Recorder")
    }
    private func reader() -> AudioInputActivity.Reader {
        .init(objects: { [7] }, pid: { _ in 42 }, running: { _ in true }, bundle: { _ in "test.recorder" }, identity: { self.process($0) }, devices: { _ in [.init(id: 11, uid: "input-one", name: "Built-in microphone")] })
    }
    func testStableActiveInputIsAttributedWithoutReadingPayloads() {
        let value = AudioInputActivity.read(reader: reader(), uid: 501)
        XCTAssertTrue(value.complete); XCTAssertEqual(value.clients.count, 1)
        XCTAssertEqual(value.clients.first?.bundleID, "test.recorder")
    }
    func testUnavailableActivityIsNotAnEmptyConfirmedList() {
        var r = reader(); r.running = { _ in nil }
        let value = AudioInputActivity.read(reader: r, uid: 501)
        XCTAssertFalse(value.complete); XCTAssertTrue(value.clients.isEmpty)
        r.objects = { nil }; XCTAssertFalse(AudioInputActivity.read(reader: r, uid: 501).available)
    }
    func testPIDReuseOrHALChangeCannotBeAttributedToOldProcess() {
        var r = reader(), calls = 0
        r.identity = { pid in calls += 1; return self.process(pid, start: calls == 1 ? 100 : 101) }
        XCTAssertFalse(AudioInputActivity.read(reader: r, uid: 501).complete)
        r = reader(); var pids = 0
        r.pid = { _ in pids += 1; return pids == 1 ? 42 : 43 }
        XCTAssertTrue(AudioInputActivity.read(reader: r, uid: 501).clients.isEmpty)
    }
    func testChangingProcessRosterInvalidatesObservation() {
        var r = reader(), calls = 0
        r.objects = { calls += 1; return calls == 1 ? [7] : [8] }
        XCTAssertFalse(AudioInputActivity.read(reader: r, uid: 501).available)
    }
    func testOtherAccountsAndDuplicateHALObjectsDoNotCreateDuplicateAlerts() {
        XCTAssertTrue(AudioInputActivity.read(reader: reader(), uid: 502).clients.isEmpty)
        var r = reader(); r.objects = { [7, 8] }
        XCTAssertEqual(AudioInputActivity.read(reader: r, uid: 501).clients.count, 1)
    }
    func testUnknownOrChangingInputDeviceDoesNotProduceAttribution() {
        var r = reader(); r.devices = { _ in nil }
        XCTAssertFalse(AudioInputActivity.read(reader: r, uid: 501).complete)
        r = reader(); var calls = 0
        r.devices = { _ in
            calls += 1
            return [.init(id: 11, uid: calls == 1 ? "old" : "new", name: "Input")]
        }
        XCTAssertTrue(AudioInputActivity.read(reader: r, uid: 501).clients.isEmpty)
    }
    func testTransitionsBaselineUnknownRecoveryMuteAndPIDReuse() {
        var state = AudioInputTransitions()
        let client = AudioInputClient(objectID: 7, process: process(), bundleID: "test.recorder")
        let active = AudioInputObservation(clients: [client])
        XCTAssertTrue(state.observe(active).isEmpty, "initial state is a baseline")
        XCTAssertTrue(state.observe(.init()).isEmpty)
        XCTAssertEqual(state.observe(active), [client])
        XCTAssertTrue(state.observe(active).isEmpty)
        XCTAssertTrue(state.observe(.init(issues: ["unreadable"])).isEmpty)
        XCTAssertTrue(state.observe(active).isEmpty, "unknown gap cannot prove a new activation")
        _ = state.observe(.init())
        XCTAssertTrue(state.observe(active, muted: ["test.recorder"]).isEmpty)
        XCTAssertTrue(state.observe(active).isEmpty, "unmuting an already active process is quiet")
        let replacement = AudioInputClient(objectID: 7, process: process(start: 101), bundleID: "test.recorder")
        XCTAssertEqual(state.observe(.init(clients: [replacement])), [replacement])
        state.reset(); XCTAssertTrue(state.observe(active).isEmpty)
    }
}
