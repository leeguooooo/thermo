import XCTest
@testable import AgentCore

@MainActor final class IdleAwakeTests: XCTestCase {
    final class Fake {
        var next: UInt32 = 0
        var entries: [UInt32: IdleAwakeObservation] = [:]
        var creates: [(IdleAwakeKind, Double)] = []
        var renewals: [Double] = []
        var releases: [UInt32] = []
        var unknown = Set<UInt32>()
        var failCreate: Int?
        var failRelease = false
        var failRenew = false
        var driver: IdleAwakeDriver {
            .init(create: { kind, _, timeout in
                if self.failCreate == self.creates.count + 1 { throw IdleAwakeDriver.Failure("fixture create failure") }
                self.creates.append((kind, timeout)); self.next += 1; self.entries[self.next] = .active; return self.next
            }, read: { id, _, _ in self.unknown.contains(id) ? .unknown : self.entries[id] ?? .absent }, renew: { _, _, _, timeout in
                if self.failRenew { throw IdleAwakeDriver.Failure("fixture renewal failure") }; self.renewals.append(timeout)
            }, release: { id, _, _ in
                self.releases.append(id)
                if self.failRelease { throw IdleAwakeDriver.Failure("fixture release failure") }; self.entries[id] = nil
            })
        }
    }
    let start = Date(timeIntervalSince1970: 1_000)
    let ac = IdleAwakePower(source: .external)

    func testModesAndKernelLeaseDoNotExtendTheRequestedDeadline() throws {
        let f = Fake()
        let controller = IdleAwakeController(driver: f.driver)
        try controller.start(mode: .both, seconds: 120, power: ac, now: start)
        XCTAssertEqual(f.creates.map(\.0), [.tasks, .display]); XCTAssertEqual(f.creates.map(\.1), [30, 30])
        controller.tick(power: ac, now: start.addingTimeInterval(110))
        XCTAssertEqual(f.renewals, [10, 10]); XCTAssertEqual(controller.state.expiresAt, start.addingTimeInterval(120))
        controller.tick(power: ac, now: start.addingTimeInterval(120))
        XCTAssertEqual(controller.state.phase, .idle); XCTAssertTrue(f.entries.isEmpty)
        XCTAssertEqual(controller.state.lastEndReason, "expired")
    }
    func testPartialCreationRollsBackAndUnconfirmedRollbackBlocksNewSession() throws {
        let f = Fake(); f.failCreate = 2
        let c = IdleAwakeController(driver: f.driver)
        XCTAssertThrowsError(try c.start(mode: .both, seconds: 120, power: ac, now: start))
        XCTAssertEqual(c.state.phase, .idle); XCTAssertTrue(f.entries.isEmpty)
        f.failRelease = true
        XCTAssertThrowsError(try c.start(mode: .both, seconds: 120, power: ac, now: start))
        // This second attempt fails before creating a request, because the fixture fails at creation #2.
        XCTAssertEqual(c.state.phase, .idle)
        let held = Fake(); held.failCreate = 2; held.failRelease = true
        let pending = IdleAwakeController(driver: held.driver)
        XCTAssertThrowsError(try pending.start(mode: .both, seconds: 120, power: ac, now: start))
        XCTAssertEqual(pending.state.phase, .ending)
        XCTAssertThrowsError(try pending.start(mode: .tasks, seconds: 120, power: ac, now: start))
        held.failRelease = false; pending.tick(power: ac, now: start.addingTimeInterval(1))
        XCTAssertEqual(pending.state.phase, .idle); XCTAssertTrue(held.entries.isEmpty)
    }
    func testLowBatteryPausesUntilPowerReturnsAndKeepsOriginalEndTime() throws {
        let f = Fake()
        let model = IdleAwakeController(driver: f.driver)
        try model.start(mode: .tasks, seconds: 120, power: ac, now: start)
        model.tick(power: .init(source: .battery, percent: 20), now: start.addingTimeInterval(10))
        XCTAssertEqual(model.state.phase, .pausedLowBattery); XCTAssertTrue(model.state.requested); XCTAssertTrue(f.entries.isEmpty)
        model.tick(power: .init(source: .battery, percent: 90), now: start.addingTimeInterval(20))
        XCTAssertEqual(model.state.phase, .pausedLowBattery); XCTAssertEqual(f.creates.count, 1)
        model.tick(power: ac, now: start.addingTimeInterval(30))
        XCTAssertEqual(model.state.phase, .active); XCTAssertEqual(f.creates.count, 2)
        XCTAssertEqual(model.state.expiresAt, start.addingTimeInterval(120))
        model.stop(); XCTAssertTrue(f.entries.isEmpty)
    }
    func testPausedSessionExpiresWithoutResumingOnPlugIn() throws {
        let f = Fake()
        let model = IdleAwakeController(driver: f.driver)
        try model.start(mode: .display, seconds: 30, power: ac, now: start)
        model.tick(power: .init(source: .battery, percent: 10), now: start.addingTimeInterval(5))
        model.tick(power: ac, now: start.addingTimeInterval(31))
        XCTAssertEqual(model.state.phase, .idle); XCTAssertEqual(f.creates.count, 1)
    }
    func testUnknownPowerAndUnknownOwnershipCannotLookLikeSuccessfulRelease() throws {
        let f = Fake()
        let model = IdleAwakeController(driver: f.driver)
        XCTAssertThrowsError(try model.start(mode: .tasks, seconds: 60, power: .init(source: .unknown), now: start))
        XCTAssertTrue(f.creates.isEmpty)
        try model.start(mode: .tasks, seconds: 60, power: ac, now: start)
        f.unknown = [1]; model.stop(now: start.addingTimeInterval(1))
        XCTAssertEqual(model.state.phase, .ending); XCTAssertTrue(f.releases.isEmpty)
        f.unknown = []; model.tick(power: ac, now: start.addingTimeInterval(2))
        XCTAssertEqual(model.state.phase, .idle); XCTAssertEqual(f.releases, [1])
    }
    func testUnknownPowerPausesAndHealthyReadingResumes() throws {
        let f = Fake(); let model = IdleAwakeController(driver: f.driver)
        try model.start(mode: .tasks, seconds: nil, power: ac, now: start)
        model.tick(power: .init(source: .unknown), now: start.addingTimeInterval(1))
        XCTAssertEqual(model.state.phase, .pausedPowerUnknown); XCTAssertTrue(f.entries.isEmpty)
        model.tick(power: .init(source: .battery, percent: 50), now: start.addingTimeInterval(2))
        XCTAssertEqual(model.state.phase, .active); model.stop()
    }
    func testLostRequestAndRenewalFailureEndWithoutRecreatingRequests() throws {
        let f = Fake(); let model = IdleAwakeController(driver: f.driver)
        try model.start(mode: .tasks, seconds: nil, power: ac, now: start)
        f.entries.removeAll(); model.tick(power: ac, now: start.addingTimeInterval(1))
        XCTAssertEqual(model.state.phase, .idle); XCTAssertEqual(model.state.lastEndReason, "requestLost")
        XCTAssertEqual(f.creates.count, 1)
        try model.start(mode: .both, seconds: nil, power: ac, now: start)
        f.failRenew = true; model.tick(power: ac, now: start.addingTimeInterval(6))
        XCTAssertEqual(model.state.phase, .idle); XCTAssertTrue(f.entries.isEmpty)
        XCTAssertEqual(model.state.lastEndReason, "renewFailed")
    }
    func testInvalidDurationsAndSecondStartDoNotMutateExistingSession() throws {
        let f = Fake(); let model = IdleAwakeController(driver: f.driver)
        for seconds in [0, -1, Double.infinity, Double.nan, 604801] {
            XCTAssertThrowsError(try model.start(mode: .tasks, seconds: seconds, power: ac, now: start))
        }
        XCTAssertTrue(f.creates.isEmpty)
        try model.start(mode: .tasks, seconds: 60, power: ac, now: start)
        XCTAssertThrowsError(try model.start(mode: .display, seconds: 60, power: ac, now: start))
        XCTAssertEqual(f.creates.count, 1); XCTAssertEqual(model.state.mode, .tasks); model.stop()
    }
    func testUncertainCreationWithoutAnIDRemainsPendingUntilAbsenceIsKnown() {
        let f = Fake(); f.failCreate = 1; f.unknown = [0]
        let model = IdleAwakeController(driver: f.driver)
        XCTAssertThrowsError(try model.start(mode: .tasks, seconds: 60, power: ac, now: start))
        XCTAssertEqual(model.state.phase, .ending); XCTAssertTrue(model.state.requested)
        XCTAssertTrue(f.releases.isEmpty)
        f.unknown = []; model.tick(power: ac, now: start.addingTimeInterval(1))
        XCTAssertEqual(model.state.phase, .idle)
    }
    func testStatusDoesNotReportExpiredOrMissingRequestsAsActiveAndDoesNotWrite() throws {
        let f = Fake(); let model = IdleAwakeController(driver: f.driver)
        try model.start(mode: .tasks, seconds: 60, power: ac, now: start)
        XCTAssertEqual(model.inspect(power: ac, now: start.addingTimeInterval(61)).phase, .ending)
        f.entries.removeAll()
        XCTAssertEqual(model.inspect(power: ac, now: start.addingTimeInterval(1)).phase, .ending)
        XCTAssertTrue(f.releases.isEmpty); XCTAssertTrue(f.renewals.isEmpty); XCTAssertEqual(f.creates.count, 1)
        model.stop()
    }
    func testBothModeChecksTheEarlierRequestAfterCreatingTheSecond() {
        let f = Fake(); var driver = f.driver
        let create = driver.create
        driver.create = { kind, name, timeout in
            let id = try create(kind, name, timeout)
            if kind == .display { f.entries[1] = nil }
            return id
        }
        let model = IdleAwakeController(driver: driver)
        XCTAssertThrowsError(try model.start(mode: .both, seconds: 60, power: ac, now: start))
        XCTAssertEqual(model.state.phase, .idle); XCTAssertTrue(f.entries.isEmpty)
    }
}
