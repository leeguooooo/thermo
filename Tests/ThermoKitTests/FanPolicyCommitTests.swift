import XCTest
@testable import ThermoKit

final class FanPolicyCommitTests: XCTestCase {
    enum Fault: Error { case disk, mode }
    let confirmed = FanAutoRecoveryReport(unconfirmed: [], requestErrors: [])

    func testManualRequestDoesNotChangeControlWhenStorageFails() {
        var policies: [Int: FanPolicy] = [0: .fixed(rpm: 4000)]
        var events: [String] = []
        XCTAssertThrowsError(try FanPolicyCommit.apply(.fixed(rpm: 2000), save: {
            events.append("save"); throw Fault.disk
        }, commit: { policies = [0: .fixed(rpm: 2000)]; events.append("commit") },
            applyAutomatic: { XCTFail("not automatic") }, restoreAll: { XCTFail("must preserve existing control"); return self.confirmed },
            recordFault: { _ in XCTFail("do not suspend the old policy on a rejected manual request") }))
        XCTAssertEqual(events, ["save"])
        XCTAssertEqual(policies, [0: .fixed(rpm: 4000)])
    }

    func testSavedManualRequestIsAlreadyReloadableBeforeControlCommits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("policies.json").path
        let requested: [Int: FanPolicy] = [0: .curve(.balanced), 1: .fixed(rpm: 4500)]
        var committed = false
        try FanPolicyCommit.apply(.curve(.balanced), save: { try PolicyStore.save(requested, to: path) }, commit: {
            XCTAssertEqual(PolicyStore.load(from: path), requested)
            committed = true
        }, applyAutomatic: { XCTFail("not automatic") }, restoreAll: { XCTFail("must not reset"); return self.confirmed },
            recordFault: { _ in XCTFail("no fault") })
        XCTAssertTrue(committed)
        XCTAssertEqual(PolicyStore.load(from: path), requested, "a new controller loads the acknowledged desired policy")
    }

    func testAutomaticRequestStillRestoresOnDiskFailureAndReportsRestartRisk() {
        var events: [String] = []
        var fault: String?
        XCTAssertThrowsError(try FanPolicyCommit.apply(.auto, save: { events.append("save"); throw Fault.disk },
            commit: { events.append("clear") }, applyAutomatic: { events.append("requested auto") },
            restoreAll: { events.append("all auto"); return self.confirmed }, recordFault: { fault = $0 }))
        XCTAssertEqual(events, ["clear", "save", "requested auto", "all auto"])
        XCTAssertTrue(fault?.contains("previous policies may return after restart") == true)
    }

    func testRecoveredAutomaticWriteCanSucceedWhenDesiredPolicyWasSaved() throws {
        var events: [String] = []
        try FanPolicyCommit.apply(.auto, save: { events.append("save") }, commit: { events.append("clear") },
            applyAutomatic: { events.append("requested auto"); throw Fault.mode },
            restoreAll: { events.append("all auto"); return self.confirmed }, recordFault: { _ in XCTFail("recovered") })
        XCTAssertEqual(events, ["clear", "save", "requested auto", "all auto"])
    }

    func testUnconfirmedRecoveryRetainsBothPersistenceAndHardwareErrors() {
        var fault: String?
        XCTAssertThrowsError(try FanPolicyCommit.apply(.auto, save: { throw Fault.disk }, commit: {},
            applyAutomatic: { throw Fault.mode }, restoreAll: { .init(unconfirmed: ["fan still manual"], requestErrors: []) },
            recordFault: { fault = $0 }))
        XCTAssertTrue(fault?.contains("disk") == true)
        XCTAssertTrue(fault?.contains("mode") == true)
        XCTAssertTrue(fault?.contains("fan still manual") == true)
    }

    func testAutomaticSaveIsReloadableAndNoFallbackRunsAfterConfirmedDirectChange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("policies.json").path
        try PolicyStore.save([0: .fixed(rpm: 2000)], to: path)
        var active: [Int: FanPolicy] = [0: .fixed(rpm: 2000)]
        try FanPolicyCommit.apply(.auto, save: { try PolicyStore.save(active, to: path) }, commit: { active = [:] },
            applyAutomatic: { XCTAssertTrue(active.isEmpty) }, restoreAll: { XCTFail("no fallback needed"); return self.confirmed },
            recordFault: { _ in XCTFail("no fault") })
        XCTAssertTrue(PolicyStore.load(from: path).isEmpty)
    }

    func testInvalidPolicyDoesNotTouchStorageOrControl() {
        XCTAssertThrowsError(try FanPolicyCommit.apply(.fixed(rpm: .nan), save: { XCTFail("invalid") },
            commit: { XCTFail("invalid") }, applyAutomatic: { XCTFail("invalid") },
            restoreAll: { XCTFail("invalid"); return self.confirmed }, recordFault: { _ in XCTFail("invalid") }))
    }

    func testRealFilesystemSaveFailureRejectsManualRequestWithoutChangingControl() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appendingPathComponent("parent-is-a-file")
        let bytes = Data("owned fixture".utf8)
        try bytes.write(to: blocker)
        XCTAssertThrowsError(try FanPolicyCommit.apply(.fixed(rpm: 2500), save: {
            try PolicyStore.save([0: .fixed(rpm: 2500)], to: blocker.appendingPathComponent("policies.json").path)
        }, commit: { XCTFail("must not commit") }, applyAutomatic: { XCTFail("must not apply") },
            restoreAll: { XCTFail("must not change control"); return self.confirmed },
            recordFault: { _ in XCTFail("existing control must remain active") }))
        XCTAssertEqual(try Data(contentsOf: blocker), bytes)
    }
}
