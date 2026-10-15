import XCTest
@testable import ThermoKit

final class LidAwakeTests: XCTestCase {
    final class FakeSwitch: @unchecked Sendable {
        var value: Bool
        var writes: [Bool] = []
        init(_ v: Bool) { value = v }
        var sleepSwitch: SleepSwitch { SleepSwitch(read: { self.value }, write: { self.value = $0; self.writes.append($0) }) }
    }
    var file = ""
    override func setUp() { file = NSTemporaryDirectory() + "lid-" + UUID().uuidString + "/before.json" }
    override func tearDown() { try? FileManager.default.removeItem(atPath: (file as NSString).deletingLastPathComponent) }

    func battery(_ percent: Double, plugged: Bool) -> BatteryInfo {
        BatteryInfo(percent: percent, temperature: nil, voltage: nil, amperage: nil, cycleCount: nil, health: nil, charging: false, externalPower: plugged)
    }

    func testTurnsOffWhenHotForTwoChecksAndNeverRearms() {
        var g = LidAwakeGuard(limits: .appleSilicon)
        XCTAssertEqual(g.state.limit, 100)
        g.arm()
        XCTAssertNil(g.tick(hottest: 101, battery: nil, lidClosed: true), "one spike is not enough")
        XCTAssertNil(g.tick(hottest: 90, battery: nil, lidClosed: true))
        XCTAssertNil(g.tick(hottest: 101, battery: nil, lidClosed: true))
        XCTAssertEqual(g.tick(hottest: 102, battery: nil, lidClosed: true)?.reason, "thermal")
        XCTAssertFalse(g.state.armed)
        XCTAssertNil(g.tick(hottest: 40, battery: nil, lidClosed: true), "cooling down does not turn it back on")
        XCTAssertFalse(g.state.armed)
    }

    func testLowBatteryOnBatteryPowerAndMissingReadingsTurnItOff() {
        var g = LidAwakeGuard(limits: .intel)
        g.arm()
        XCTAssertNil(g.tick(hottest: 50, battery: battery(15, plugged: true), lidClosed: false), "plugged in: low battery is fine")
        XCTAssertEqual(g.tick(hottest: 50, battery: battery(20, plugged: false), lidClosed: false)?.reason, "battery")
        g.arm()
        XCTAssertNil(g.tick(hottest: nil, battery: nil, lidClosed: nil))
        XCTAssertNil(g.tick(hottest: .nan, battery: nil, lidClosed: nil))
        XCTAssertEqual(g.tick(hottest: nil, battery: nil, lidClosed: nil)?.reason, "noReading")
    }

    func testRestoresWhatTheUserHadOnOffAutoOffAndRestart() throws {
        let fake = FakeSwitch(false)
        let c = LidAwakeController(limits: .appleSilicon, sleep: fake.sleepSwitch, originalFile: file)
        try c.set(true)
        XCTAssertTrue(fake.value)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file))
        try c.set(false)
        XCTAssertFalse(fake.value)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file))

        // A user who already had sleep disabled keeps it after Thermo turns off.
        let already = FakeSwitch(true)
        let d = LidAwakeController(limits: .appleSilicon, sleep: already.sleepSwitch, originalFile: file)
        try d.set(true)
        _ = d.tick(hottest: 105, battery: nil, lidClosed: true)
        XCTAssertEqual(d.tick(hottest: 105, battery: nil, lidClosed: true)?.reason, "thermal")
        XCTAssertTrue(already.value)
        XCTAssertEqual(d.state.lastAutoOff?.reason, "thermal")
        XCTAssertFalse(d.state.armed)

        // Crash while on: the next helper start restores the recorded value.
        let crashed = FakeSwitch(false)
        try LidAwakeController(limits: .intel, sleep: crashed.sleepSwitch, originalFile: file).set(true)
        XCTAssertTrue(crashed.value)
        let restarted = LidAwakeController(limits: .intel, sleep: crashed.sleepSwitch, originalFile: file)
        restarted.restoreOriginal(reason: "helper started")
        XCTAssertFalse(crashed.value)
        XCTAssertFalse(restarted.state.armed)
    }

    func testRefusesWhenTheCurrentSettingCannotBeRead() {
        let c = LidAwakeController(limits: .intel, sleep: SleepSwitch(read: { nil }, write: { _ in XCTFail("must not write") }), originalFile: file)
        XCTAssertThrowsError(try c.set(true))
        XCTAssertFalse(c.state.armed)
    }
}
