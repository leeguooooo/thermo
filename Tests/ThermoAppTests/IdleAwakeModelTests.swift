import XCTest
import AgentCore
@testable import ThermoApp

@MainActor final class IdleAwakeModelTests: XCTestCase {
    final class Backend {
        var counter: UInt32 = 0
        var ids = Set<UInt32>()
        var created = 0, released = 0, renewed = 0
        var unknown = false
        var power = IdleAwakePower(source: .external)
        var now = Date(timeIntervalSince1970: 1000)
        var events: [OperationRecord] = []
        var driver: IdleAwakeDriver {
            .init(create: { _, _, _ in self.counter += 1; self.created += 1; self.ids.insert(self.counter); return self.counter },
                  read: { id, _, _ in self.unknown ? .unknown : self.ids.contains(id) ? .active : .absent },
                  renew: { _, _, _, _ in self.renewed += 1 },
                  release: { id, _, _ in self.released += 1; self.ids.remove(id) })
        }
        @MainActor func model() -> IdleAwakeModel {
            IdleAwakeModel(controller: IdleAwakeController(driver: driver), power: { self.power }, now: { self.now }, automaticallyMonitor: false,
                           record: { self.events.append($0) })
        }
    }
    func testEachTransitionUsesOneConsistentPowerAndClockSnapshot() {
        let b = Backend()
        var powerReads = 0, clockReads = 0
        let model = IdleAwakeModel(controller: IdleAwakeController(driver: b.driver),
            power: { powerReads += 1; return b.power }, now: { clockReads += 1; return b.now },
            automaticallyMonitor: false, record: { b.events.append($0) })
        powerReads = 0; clockReads = 0
        model.start(mode: .both, seconds: 120)
        XCTAssertEqual(powerReads, 1); XCTAssertEqual(clockReads, 1)
        XCTAssertEqual(model.state.expiresAt, b.now.addingTimeInterval(120))
        b.power = .init(source: .battery, percent: 20); b.now.addTimeInterval(5)
        powerReads = 0; clockReads = 0
        model.refresh()
        XCTAssertEqual(powerReads, 1); XCTAssertEqual(clockReads, 1)
        XCTAssertEqual(model.state.phase, .pausedLowBattery)
        b.power = .init(source: .external); b.now.addTimeInterval(5)
        powerReads = 0; clockReads = 0
        model.refresh()
        XCTAssertEqual(powerReads, 1); XCTAssertEqual(clockReads, 1)
        XCTAssertEqual(model.state.phase, .active)
        powerReads = 0; clockReads = 0
        model.stop()
        XCTAssertEqual(powerReads, 1); XCTAssertEqual(clockReads, 1)
        XCTAssertTrue(b.ids.isEmpty)
    }

    func testDeadlineFiresBetweenPollingTicksAndStaleCallbacksCannotEndNewSession() throws {
        let b = Backend()
        var callbacks: [@MainActor () -> Void] = [], timers: [Timer] = []
        let model = IdleAwakeModel(controller: IdleAwakeController(driver: b.driver),
            power: { b.power }, now: { b.now }, record: { b.events.append($0) },
            scheduleDeadline: { end, callback in
                callbacks.append(callback)
                let timer = Timer(fire: end, interval: 0, repeats: false) { _ in }
                timers.append(timer)
                return timer
            })
        model.start(mode: .both, seconds: 20.25)
        let end = b.now.addingTimeInterval(20.25)
        XCTAssertEqual(model.scheduledDeadline, end)
        let expire = try XCTUnwrap(callbacks.first)
        b.now.addTimeInterval(5.1); model.refresh()
        XCTAssertEqual(callbacks.count, 1)
        b.power = .init(source: .battery, percent: 20); model.refresh()
        XCTAssertEqual(model.state.phase, .pausedLowBattery)
        XCTAssertEqual(model.scheduledDeadline, end)
        b.now = end; expire()
        XCTAssertEqual(model.state.lastEndReason, "expired")
        XCTAssertNil(model.scheduledDeadline)
        XCTAssertTrue(b.ids.isEmpty)
        b.power = .init(source: .external)
        model.start(mode: .tasks, seconds: 60)
        XCTAssertEqual(callbacks.count, 2)
        expire()
        XCTAssertEqual(model.state.phase, .active)
        XCTAssertEqual(model.scheduledDeadline, end.addingTimeInterval(60))
        model.stop()
        XCTAssertNil(model.scheduledDeadline)
        XCTAssertFalse(timers[1].isValid)
        model.start(mode: .display, seconds: nil)
        XCTAssertNil(model.scheduledDeadline)
        callbacks[1]()
        XCTAssertEqual(model.state.phase, .active)
        model.stop()
    }
    func testUnconfirmedDeadlineReleaseDoesNotContinuouslyRearmPastDeadline() throws {
        let b = Backend()
        var callbacks: [@MainActor () -> Void] = []
        let model = IdleAwakeModel(controller: IdleAwakeController(driver: b.driver),
            power: { b.power }, now: { b.now }, record: { b.events.append($0) },
            scheduleDeadline: { end, callback in
                callbacks.append(callback)
                return Timer(fire: end, interval: 0, repeats: false) { _ in }
            })
        model.start(mode: .tasks, seconds: 1.25)
        let expire = try XCTUnwrap(callbacks.first)
        b.unknown = true; b.now.addTimeInterval(1.25); expire()
        XCTAssertEqual(model.state.phase, .ending)
        XCTAssertNil(model.scheduledDeadline)
        XCTAssertEqual(callbacks.count, 1)
        XCTAssertFalse(model.canStart)
        b.now.addTimeInterval(1); model.refresh()
        XCTAssertEqual(callbacks.count, 1)
        b.unknown = false; model.refresh()
        XCTAssertEqual(model.state.phase, .idle)
        XCTAssertTrue(b.ids.isEmpty)
    }

    func testInitializationAndClosingThePanelDoNotStartOrEndASession() {
        let b = Backend()
        let live = b.model(); live.open(); XCTAssertEqual(b.created,0)
        live.start(mode: .both, seconds: 120); live.close()
        XCTAssertEqual(b.created,2); XCTAssertEqual(b.released,0); XCTAssertTrue(live.state.requested)
        b.now.addTimeInterval(5); live.refresh(); XCTAssertEqual(b.renewed,2)
        live.stop(); XCTAssertTrue(b.ids.isEmpty); XCTAssertFalse(live.state.requested)
    }
    func testPowerPauseResumeAndExpiryUseTheSameVisibleModel() {
        let b = Backend(); let model = b.model()
        model.start(mode: .tasks, seconds: 60)
        b.power = .init(source: .battery, percent: 20); b.now.addTimeInterval(5); model.refresh()
        XCTAssertEqual(model.state.phase,.pausedLowBattery); XCTAssertTrue(b.ids.isEmpty)
        b.power = .init(source: .external); b.now.addTimeInterval(5); model.refresh()
        XCTAssertEqual(model.state.phase,.active); XCTAssertEqual(b.created,2)
        b.now.addTimeInterval(51); model.refresh()
        XCTAssertEqual(model.state.phase,.idle); XCTAssertTrue(b.ids.isEmpty)
        XCTAssertTrue(b.events.contains { $0.action == "idleAwakePause" })
        XCTAssertTrue(b.events.contains { $0.action == "idleAwakeResume" })
        XCTAssertTrue(b.events.contains { $0.action == "idleAwakeEnd" })
    }
    func testControlPreviewValidationAndReplayNeverCreateExtraRequests() async {
        let b = Backend(); let model = b.model(); let host = AppControlHost(idleAwake: model)
        let arguments = ["mode":"tasks","seconds":"60"]
        let preview = await host.handle(.init(action:"keep-awake.start",arguments:arguments,dryRun:true))
        XCTAssertTrue(preview.succeeded); XCTAssertEqual(preview.values["changesMade"],"false"); XCTAssertEqual(b.created,0)
        for arguments in [["mode":"wrong","seconds":"60"],["mode":"both","seconds":"0"],["mode":"both","duration":"manual","seconds":"60"],["mode":"both","extra":"value"]] {
            let bad = await host.handle(.init(action:"keep-awake.start",arguments:arguments,dryRun:true))
            XCTAssertFalse(bad.succeeded)
        }
        XCTAssertEqual(b.created,0)
        let request = AppControlRequest(action:"keep-awake.start",arguments:arguments)
        let start = await host.handle(request); XCTAssertTrue(start.succeeded); XCTAssertEqual(start.values["phase"],"active")
        let replay = await host.handle(request); XCTAssertFalse(replay.succeeded)
        let duplicate = await host.handle(.init(action:"keep-awake.start",arguments:arguments)); XCTAssertFalse(duplicate.succeeded)
        XCTAssertEqual(b.created,1)
        let stop = await host.handle(.init(action:"keep-awake.stop")); XCTAssertTrue(stop.succeeded); XCTAssertTrue(b.ids.isEmpty)
    }
    func testStatusIsReadOnlyAndUnconfirmedStopDoesNotClaimSuccess() async {
        let b = Backend(); let model = b.model(); let host = AppControlHost(idleAwake:model)
        model.start(mode:.tasks,seconds:nil)
        b.unknown = true
        let status = await host.handle(.init(action:"keep-awake.status"))
        XCTAssertFalse(status.succeeded); XCTAssertEqual(status.values["phase"],"ending")
        XCTAssertEqual(b.released,0); XCTAssertEqual(b.renewed,0)
        let stop = await host.handle(.init(action:"keep-awake.stop")); XCTAssertFalse(stop.succeeded)
        XCTAssertTrue(model.state.requested); XCTAssertFalse(model.canStart); XCTAssertEqual(b.released,0)
        XCTAssertEqual(b.events.last?.outcome,"partial"); XCTAssertEqual(b.events.last?.items.first?.status,"partial")
        b.unknown = false; model.refresh(); XCTAssertEqual(model.state.phase,.idle); XCTAssertTrue(b.ids.isEmpty)
    }
}
