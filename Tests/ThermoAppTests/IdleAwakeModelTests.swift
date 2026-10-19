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
