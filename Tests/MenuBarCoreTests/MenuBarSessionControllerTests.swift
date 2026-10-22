import XCTest
@testable import MenuBarCore

@MainActor final class MenuBarSessionControllerTests: XCTestCase {
    final class FakeSession: MenuBarVisibilitySession {
        var completion: (@MainActor (String?) -> Void)?
        var invalidations = 0
        var restorationError: String?
        var synchronouslyComplete = false
        func activate(completion: @escaping @MainActor (String?) -> Void) {
            self.completion = completion
            if synchronouslyComplete { finish() }
        }
        func invalidate() -> String? { invalidations += 1; return restorationError }
        func finish(_ error: String? = nil) { let callback = completion; completion = nil; callback?(error) }
    }
    let a = MenuBarConfiguration(allowedBundles: ["org.example.a"])
    let b = MenuBarConfiguration(allowedBundles: ["org.example.b"])

    func testReplacementActivatesBeforePreviousHandleIsReleased() {
        var sessions: [FakeSession] = []
        let controller = MenuBarSessionController { _ in let s = FakeSession(); sessions.append(s); return s }
        controller.apply(a); sessions[0].finish()
        XCTAssertEqual(controller.state, .applied)
        controller.apply(b)
        XCTAssertEqual(sessions[0].invalidations, 0)
        XCTAssertEqual(controller.state, .applying)
        sessions[1].finish()
        XCTAssertEqual(sessions[0].invalidations, 1)
        XCTAssertEqual(controller.state, .applied)
        controller.restore()
        XCTAssertEqual(sessions[1].invalidations, 1)
        XCTAssertEqual(controller.state, .visible)
    }

    func testFailureReleasesBothActiveAndPendingSessions() {
        var sessions: [FakeSession] = []
        let controller = MenuBarSessionController { _ in let s = FakeSession(); sessions.append(s); return s }
        controller.apply(a); sessions[0].finish(); controller.apply(b)
        sessions[1].finish("activation failed")
        XCTAssertEqual(controller.state, .failed("activation failed"))
        XCTAssertEqual(sessions.map(\.invalidations), [1, 1])
    }

    func testLateSuccessAfterRestoreIsInvalidatedAgain() {
        let session = FakeSession()
        let controller = MenuBarSessionController { _ in session }
        controller.apply(a); controller.restore()
        session.finish()
        XCTAssertEqual(session.invalidations, 2)
        XCTAssertEqual(controller.state, .visible)
    }

    func testSupersededCallbackCannotReleaseNewActiveSession() {
        var sessions: [FakeSession] = []
        let controller = MenuBarSessionController { _ in let s = FakeSession(); sessions.append(s); return s }
        controller.apply(a); controller.apply(b); sessions[1].finish()
        sessions[0].finish("late failure")
        XCTAssertEqual(controller.state, .applied)
        XCTAssertEqual(sessions[0].invalidations, 2)
        XCTAssertEqual(sessions[1].invalidations, 0)
        controller.restore()
    }

    func testSameConfigurationDoesNotRestartPendingOrAppliedWork() {
        var created = 0
        let session = FakeSession()
        let controller = MenuBarSessionController { _ in created += 1; return session }
        controller.apply(a); controller.apply(a)
        session.finish(); controller.apply(a)
        XCTAssertEqual(created, 1)
        controller.apply(nil)
        XCTAssertEqual(session.invalidations, 1)
    }

    func testTimeoutRestoresAndLateSuccessCannotHideAgain() async throws {
        let session = FakeSession()
        let controller = MenuBarSessionController(timeoutNanoseconds: 1_000_000) { _ in session }
        controller.apply(a)
        for _ in 0..<100 {
            if case .failed = controller.state { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard case .failed = controller.state else { return XCTFail("request did not time out") }
        XCTAssertEqual(session.invalidations, 1)
        session.finish()
        XCTAssertEqual(session.invalidations, 2)
        controller.restore()
    }

    func testRestorationFailureIsRetainedForExplicitRecovery() {
        let session = FakeSession()
        let controller = MenuBarSessionController { _ in session }
        controller.apply(a); session.finish()
        session.restorationError = "restore failed"
        controller.restore()
        XCTAssertEqual(controller.state, .failed("restore failed"))
        session.restorationError = nil
        controller.restore()
        XCTAssertEqual(controller.state, .visible)
        XCTAssertEqual(session.invalidations, 2)
    }

    func testSynchronousCallbackDoesNotLeaveApplyingStateOrScheduleTimeout() async throws {
        let session = FakeSession(); session.synchronouslyComplete = true
        let controller = MenuBarSessionController(timeoutNanoseconds: 1_000_000) { _ in session }
        controller.apply(a)
        try await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(controller.state, .applied)
        XCTAssertEqual(session.invalidations, 0)
        controller.restore()
    }
}
