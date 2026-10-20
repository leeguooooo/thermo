import XCTest
import CoreAudio
@testable import AgentCore

private final class AudioListenerFixture: @unchecked Sendable {
    typealias Key = AudioInputActivity.Watcher.Key
    private let lock = NSLock()
    private var roster: [UInt32]? = [10, 20]
    private var handlers: [Key: @Sendable () -> Void] = [:]
    private var changes = 0
    private var coverage: Bool?
    var rejectRunning = false
    func objects() -> [UInt32]? { lock.lock(); defer { lock.unlock() }; return roster }
    func setObjects(_ value: [UInt32]?) { lock.lock(); roster = value; lock.unlock() }
    func keys() -> Set<Key> { lock.lock(); defer { lock.unlock() }; return Set(handlers.keys) }
    func changed() { lock.lock(); changes += 1; lock.unlock() }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return changes }
    func covered(_ value: Bool) { lock.lock(); coverage = value; lock.unlock() }
    func isCovered() -> Bool? { lock.lock(); defer { lock.unlock() }; return coverage }
    func callback(_ key: Key) -> (@Sendable () -> Void)? { lock.lock(); defer { lock.unlock() }; return handlers[key] }
    var operations: AudioInputActivity.Watcher.Operations {
        .init(objects: { self.objects() }, add: { key, callback in
            self.lock.lock(); defer { self.lock.unlock() }
            if self.rejectRunning && key.selector == kAudioProcessPropertyIsRunningInput { return false }
            self.handlers[key] = callback; return true
        }, remove: { key in self.lock.lock(); self.handlers.removeValue(forKey: key); self.lock.unlock() })
    }
}

final class AudioInputWatcherTests: XCTestCase {
    private var root: AudioInputActivity.Watcher.Key {
        .init(object: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyProcessObjectList)
    }
    private func wait(_ check: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 {
            if check() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("audio listeners did not settle", file: file, line: line)
    }
    func testRosterChangesRetireOldListenersAndStopRemovesEveryRegistration() async {
        let fixture = AudioListenerFixture()
        let watcher = AudioInputActivity.Watcher(operations: fixture.operations,
            changed: { fixture.changed() }, coverage: { fixture.covered($0) })
        watcher.start(); await wait { fixture.keys().count == 5 && fixture.isCovered() == true }
        let old = fixture.callback(.init(object: 10, selector: kAudioProcessPropertyIsRunningInput))
        fixture.setObjects([20, 30]); fixture.callback(root)?()
        await wait { fixture.count() == 1 && fixture.keys().contains(where: { $0.object == 30 }) }
        XCTAssertFalse(fixture.keys().contains { $0.object == 10 })
        // A queued callback belonging to a retired process must not become a new activity event.
        old?(); fixture.callback(root)?()
        await wait { fixture.count() >= 2 }
        XCTAssertEqual(fixture.count(), 2)
        watcher.stop(); await wait { fixture.keys().isEmpty }
    }
    func testUnreadableRosterRetainsListenersAndReportsDegradedCoverage() async {
        let fixture = AudioListenerFixture()
        let watcher = AudioInputActivity.Watcher(operations: fixture.operations,
            changed: { fixture.changed() }, coverage: { fixture.covered($0) })
        watcher.start(); await wait { fixture.keys().count == 5 && fixture.isCovered() == true }
        fixture.setObjects(nil); fixture.callback(root)?()
        await wait { fixture.count() == 1 && fixture.isCovered() == false }
        XCTAssertEqual(fixture.keys().count, 5)
        fixture.setObjects([]); fixture.callback(root)?()
        await wait { fixture.count() == 2 && fixture.keys().count == 1 && fixture.isCovered() == true }
        watcher.stop(); await wait { fixture.keys().isEmpty }
    }
    func testRegistrationFailureDoesNotClaimCompleteEventCoverage() async {
        let fixture = AudioListenerFixture(); fixture.rejectRunning = true
        let watcher = AudioInputActivity.Watcher(operations: fixture.operations,
            changed: { fixture.changed() }, coverage: { fixture.covered($0) })
        watcher.start(); await wait { fixture.keys().count == 3 && fixture.isCovered() == false }
        watcher.stop(); await wait { fixture.keys().isEmpty }
    }
}
