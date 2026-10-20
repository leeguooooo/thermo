import CoreMediaIO
import XCTest
@testable import AgentCore

private final class CameraListeners: @unchecked Sendable {
    typealias Key = CameraActivity.Watcher.Key
    private let lock = NSLock()
    private var objects: [UInt32]? = [10]
    private var callbacks: [Key: @Sendable () -> Void] = [:]
    private var coverage = false
    private var changes = 0
    var rejectRunning = false
    func roster(_ value: [UInt32]?) { lock.lock(); objects = value; lock.unlock() }
    func snapshot() -> (Set<Key>, Bool, Int) { lock.lock(); defer { lock.unlock() }; return (Set(callbacks.keys), coverage, changes) }
    func callback(_ key: Key) -> (@Sendable () -> Void)? { lock.lock(); defer { lock.unlock() }; return callbacks[key] }
    func changed() { lock.lock(); changes += 1; lock.unlock() }
    func covered(_ value: Bool) { lock.lock(); coverage = value; lock.unlock() }
    var operations: CameraActivity.Watcher.Operations {
        .init(objects: { self.lock.lock(); defer { self.lock.unlock() }; return self.objects }, add: { key, callback in
            self.lock.lock(); defer { self.lock.unlock() }
            if self.rejectRunning && key.selector == UInt32(kCMIODevicePropertyDeviceIsRunningSomewhere) { return false }
            self.callbacks[key] = callback; return true
        }, remove: { key in self.lock.lock(); self.callbacks.removeValue(forKey: key); self.lock.unlock(); return true })
    }
}
final class CameraActivityWatcherTests: XCTestCase {
    private let root = CameraActivity.Watcher.Key(object: UInt32(kCMIOObjectSystemObject), selector: UInt32(kCMIOHardwarePropertyDevices))
    private func wait(_ check: () -> Bool) async {
        for _ in 0..<1000 { if check() { return }; try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTFail("camera listeners did not settle")
    }
    func testHotplugRetiresListenersAndDisableIgnoresLateCallbacks() async {
        let fixture = CameraListeners()
        let watcher = CameraActivity.Watcher(operations: fixture.operations, changed: { fixture.changed() }, coverage: { fixture.covered($0) })
        watcher.start(); await wait { fixture.snapshot().0.count == 4 && fixture.snapshot().1 }
        let old = fixture.callback(.init(object: 10, selector: UInt32(kCMIODevicePropertyDeviceIsRunningSomewhere)))
        fixture.roster([20]); fixture.callback(root)?()
        await wait { fixture.snapshot().2 == 1 && fixture.snapshot().0.contains(where: { $0.object == 20 }) }
        XCTAssertFalse(fixture.snapshot().0.contains { $0.object == 10 })
        watcher.stop(); await wait { fixture.snapshot().0.isEmpty }
        old?(); for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(fixture.snapshot().2, 1)
    }
    func testUnreadableRosterIsDegradedAndRetryRecovers() async {
        let fixture = CameraListeners()
        let watcher = CameraActivity.Watcher(operations: fixture.operations, changed: { fixture.changed() }, coverage: { fixture.covered($0) })
        watcher.start(); await wait { fixture.snapshot().1 }
        fixture.roster(nil); watcher.refresh(); await wait { !fixture.snapshot().1 }
        XCTAssertEqual(fixture.snapshot().0.count, 4)
        fixture.roster([]); watcher.refresh(); await wait { fixture.snapshot().1 && fixture.snapshot().0.count == 1 }
        watcher.stop(); await wait { fixture.snapshot().0.isEmpty }
    }
    func testRegistrationFailureNeverClaimsEventCoverage() async {
        let fixture = CameraListeners(); fixture.rejectRunning = true
        let watcher = CameraActivity.Watcher(operations: fixture.operations, changed: { fixture.changed() }, coverage: { fixture.covered($0) })
        watcher.start(); await wait { fixture.snapshot().0.count == 3 }
        XCTAssertFalse(fixture.snapshot().1)
        watcher.stop(); await wait { fixture.snapshot().0.isEmpty }
    }
}
