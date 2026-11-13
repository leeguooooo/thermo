import XCTest
@testable import ModuleKit

final class ModuleLifecycleTests: XCTestCase {
    typealias Effect = ModuleLifecycle.Effect
    let timing = ModuleLifecycle.Timing(idleTimeout: 120, firstBackoff: 1, longestBackoff: 60, stableRun: 30)

    func machine(_ launch: ModuleManifest.Launch, enabled: Bool = true) -> ModuleLifecycle {
        ModuleLifecycle(launch: launch, enabled: enabled, timing: timing)
    }

    func testOnDemandStartsOnUseAndStopsAfterBeingIdle() {
        var m = machine(.onDemand)
        XCTAssertEqual(m.handle(.tick, now: 0), [])
        XCTAssertEqual(m.phase, .stopped)
        XCTAssertNil(m.deadline)
        XCTAssertEqual(m.handle(.acquire, now: 10), [.start])
        XCTAssertEqual(m.handle(.started, now: 10.1), [])
        // In use: never stopped, however long.
        XCTAssertNil(m.deadline)
        XCTAssertEqual(m.handle(.tick, now: 10_000), [])
        XCTAssertEqual(m.handle(.release, now: 20_000), [])
        XCTAssertEqual(m.deadline, 20_120)
        XCTAssertEqual(m.handle(.tick, now: 20_119), [])
        XCTAssertEqual(m.phase, .running)
        XCTAssertEqual(m.handle(.tick, now: 20_120), [.stop])
        XCTAssertEqual(m.handle(.exited, now: 20_120.2), [])
        XCTAssertEqual(m.phase, .stopped)
        XCTAssertEqual(m.crashes, 0)
        XCTAssertNil(m.deadline)
        // Used again: started again.
        XCTAssertEqual(m.handle(.acquire, now: 30_000), [.start])
    }

    func testUseDuringTheIdleWaitKeepsItRunning() {
        var m = machine(.onDemand)
        _ = m.handle(.acquire, now: 0); _ = m.handle(.started, now: 0); _ = m.handle(.release, now: 5)
        XCTAssertEqual(m.deadline, 125)
        XCTAssertEqual(m.handle(.acquire, now: 100), [])
        XCTAssertNil(m.deadline)
        XCTAssertEqual(m.handle(.release, now: 200), [])
        XCTAssertEqual(m.deadline, 320)
    }

    func testTwoUsesBothHaveToEnd() {
        var m = machine(.onDemand)
        _ = m.handle(.acquire, now: 0); _ = m.handle(.acquire, now: 0); _ = m.handle(.started, now: 0)
        XCTAssertEqual(m.handle(.release, now: 1), [])
        XCTAssertNil(m.deadline)
        XCTAssertEqual(m.handle(.release, now: 2), [])
        XCTAssertEqual(m.deadline, 122)
    }

    func testAlwaysRunsWhileOnAndIsNeverIdled() {
        for launch in [ModuleManifest.Launch.always, .prewarm] {
            var m = machine(launch, enabled: false)
            XCTAssertEqual(m.handle(.enable, now: 0), [.start])
            XCTAssertEqual(m.handle(.started, now: 0), [])
            XCTAssertNil(m.deadline)
            XCTAssertEqual(m.handle(.tick, now: 1_000_000), [])
            XCTAssertEqual(m.phase, .running)
        }
    }

    func testCrashesBackOffAndAStableRunForgetsThem() {
        var m = machine(.always, enabled: false)
        _ = m.handle(.enable, now: 0); _ = m.handle(.started, now: 0)
        var now: TimeInterval = 1
        var waits: [TimeInterval] = []
        for _ in 0..<8 {
            XCTAssertEqual(m.handle(.exited, now: now), [])
            XCTAssertEqual(m.phase, .waiting)
            let due = m.deadline!
            waits.append(due - now)
            XCTAssertEqual(m.handle(.tick, now: due - 0.01), [], "no restart before the wait is over")
            XCTAssertEqual(m.handle(.tick, now: due), [.start])
            XCTAssertEqual(m.handle(.started, now: due), [])
            now = due + 1
        }
        XCTAssertEqual(waits, [1, 2, 4, 8, 16, 32, 60, 60])
        // Runs 31 s, then crashes: counted as the first crash again.
        XCTAssertEqual(m.handle(.exited, now: now + 31), [])
        XCTAssertEqual(m.crashes, 1)
        XCTAssertEqual(m.deadline, now + 32)
    }

    func testAFailedStartCountsAsACrash() {
        var m = machine(.always, enabled: false)
        XCTAssertEqual(m.handle(.enable, now: 0), [.start])
        XCTAssertEqual(m.handle(.startFailed, now: 0), [])
        XCTAssertEqual(m.phase, .waiting)
        XCTAssertEqual(m.deadline, 1)
    }

    func testOnDemandCrashDoesNotRestartUnlessUsedAndUseWaitsOutTheBackoff() {
        var m = machine(.onDemand)
        _ = m.handle(.acquire, now: 0); _ = m.handle(.started, now: 0); _ = m.handle(.release, now: 1)
        XCTAssertEqual(m.handle(.exited, now: 2), [])
        XCTAssertEqual(m.phase, .stopped)
        XCTAssertNil(m.deadline)
        XCTAssertEqual(m.handle(.acquire, now: 2.5), [])
        XCTAssertEqual(m.phase, .waiting)
        XCTAssertEqual(m.deadline, 3)
        XCTAssertEqual(m.handle(.tick, now: 3), [.start])
    }

    func testSwitchingOffStopsItAndLeavesNothingScheduled() {
        // Running and idle-waiting.
        var m = machine(.onDemand)
        _ = m.handle(.acquire, now: 0); _ = m.handle(.started, now: 0); _ = m.handle(.release, now: 1)
        XCTAssertNotNil(m.deadline)
        XCTAssertEqual(m.handle(.disable, now: 2), [.stop])
        XCTAssertNil(m.deadline)
        XCTAssertEqual(m.handle(.exited, now: 2.1), [])
        XCTAssertEqual(m.phase, .stopped)
        XCTAssertEqual(m.crashes, 0)
        // Off: use does not start it.
        XCTAssertEqual(m.handle(.acquire, now: 3), [])
        XCTAssertEqual(m.handle(.tick, now: 1_000), [])
        XCTAssertNil(m.deadline)

        // Waiting to restart after a crash.
        var c = machine(.always, enabled: false)
        _ = c.handle(.enable, now: 0); _ = c.handle(.started, now: 0); _ = c.handle(.exited, now: 1)
        XCTAssertEqual(c.phase, .waiting)
        XCTAssertEqual(c.handle(.disable, now: 1.5), [])
        XCTAssertEqual(c.phase, .stopped)
        XCTAssertNil(c.deadline)
        XCTAssertEqual(c.handle(.tick, now: 10), [])
        // Switched on again: starts at once, the old crashes are forgotten.
        XCTAssertEqual(c.handle(.enable, now: 11), [.start])
    }

    func testSwitchedOffWhileStartingIsStoppedAsSoonAsItIsUp() {
        var m = machine(.always, enabled: false)
        XCTAssertEqual(m.handle(.enable, now: 0), [.start])
        XCTAssertEqual(m.handle(.disable, now: 0.1), [])
        XCTAssertEqual(m.handle(.started, now: 0.2), [.stop])
        XCTAssertEqual(m.handle(.exited, now: 0.3), [])
        XCTAssertEqual(m.phase, .stopped)
        XCTAssertNil(m.deadline)
    }

    func testSwitchedOnWhileStoppingStartsAfterTheOldProcessIsGone() {
        var m = machine(.always, enabled: false)
        _ = m.handle(.enable, now: 0); _ = m.handle(.started, now: 0)
        XCTAssertEqual(m.handle(.disable, now: 1), [.stop])
        XCTAssertEqual(m.handle(.enable, now: 1.1), [])
        XCTAssertEqual(m.handle(.exited, now: 1.2), [.start])
        XCTAssertEqual(m.crashes, 0)
    }
}
