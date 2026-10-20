import XCTest
@testable import AgentCore

final class CameraActivityTests: XCTestCase {
    private let device = CameraDevice(objectID: 10, uid: "private-camera-uid", name: "Camera", active: true)
    private func reader(_ device: CameraDevice?) -> CameraActivity.Reader {
        .init(objects: { [10] }, streams: { _ in [20] }, device: { _ in device })
    }
    func testStableActiveMetadataAndOutputOnlyDevicesAreDistinguished() {
        let result = CameraActivity.read(reader: reader(device))
        XCTAssertTrue(result.complete); XCTAssertEqual(result.devices, [device])
        let output = CameraActivity.read(reader: .init(objects: { [10] }, streams: { _ in [] }, device: { _ in XCTFail("output-only device read"); return nil }))
        XCTAssertTrue(output.complete); XCTAssertTrue(output.devices.isEmpty)
    }
    func testUnreadableInventoryOrPropertiesCannotBecomeIdle() {
        let missing = CameraActivity.read(reader: .init(objects: { nil }, streams: { _ in [] }, device: { _ in nil }))
        XCTAssertFalse(missing.available); XCTAssertFalse(missing.complete)
        let result = CameraActivity.read(reader: reader(nil))
        XCTAssertTrue(result.available); XCTAssertFalse(result.complete)
        let report = CameraReport(observation: result, source: "test")
        XCTAssertEqual(report.state, "unknown")
    }
    func testObjectReuseAndChangingStreamLayoutAreRejected() {
        var calls = 0
        let old = device
        let result = CameraActivity.read(reader: .init(objects: { [10] }, streams: { _ in [20] }, device: { _ in
            calls += 1
            var value = old; if calls > 1 { value.uid = "reused" }; return value
        }))
        XCTAssertFalse(result.complete); XCTAssertTrue(result.devices.isEmpty)
        var streams = 0
        let outputChanged = CameraActivity.read(reader: .init(objects: { [10] }, streams: { _ in streams += 1; return streams == 1 ? [] : [20] }, device: { _ in old }))
        XCTAssertFalse(outputChanged.complete)
    }
    func testDuplicateAndChangedRostersAreRejectedWhileOrderingMayChange() {
        var r = reader(device); r.objects = { [10, 10] }
        XCTAssertFalse(CameraActivity.read(reader: r).available)
        var calls = 0
        r.objects = { calls += 1; return calls == 1 ? [10] : [] }
        XCTAssertFalse(CameraActivity.read(reader: r).complete)
    }
    func testTransitionsStartQuietAndUnknownRecoveryCannotInventActivation() {
        var transitions = CameraTransitions(), idle = device; idle.active = false
        XCTAssertTrue(transitions.observe(.init(devices: [device])).isEmpty)
        XCTAssertTrue(transitions.observe(.init(devices: [idle])).isEmpty)
        XCTAssertEqual(transitions.observe(.init(devices: [device])), [device])
        XCTAssertTrue(transitions.observe(.init(devices: [device])).isEmpty)
        XCTAssertTrue(transitions.observe(.init(issues: ["unreadable"])).isEmpty)
        XCTAssertTrue(transitions.observe(.init(devices: [device])).isEmpty)
        transitions.reset(); XCTAssertTrue(transitions.observe(.init(devices: [device])).isEmpty)
    }
    func testReportSeparatesEmptyUnknownStaleAndNotCollectedAndOmitsUID() throws {
        XCTAssertEqual(CameraReport(observation: .init(), source: "test").state, "noDevices")
        XCTAssertEqual(CameraReport(observation: nil, source: "test").state, "notCollected")
        XCTAssertEqual(CameraReport(observation: nil, source: "test", enabled: true).state, "checking")
        let report = CameraReport(observation: .init(devices: [device], sampled: Date().addingTimeInterval(-30)), source: "test")
        XCTAssertEqual(report.state, "stale"); XCTAssertEqual(report.processAttribution, "unavailable")
        let data = try JSONEncoder().encode(report)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-camera-uid"))
        XCTAssertFalse(report.recordsVideo)
    }
    func testLargeAndNonFiniteReportsRemainBoundedAndEncodable() throws {
        var large = device; large.name = String(repeating: "x", count: 4096)
        let report = CameraReport(observation: .init(devices: Array(repeating: large, count: 256), sampled: Date(timeIntervalSinceReferenceDate: .nan)), source: "test", notificationIssue: String(repeating: "error", count: 1000))
        XCTAssertNil(report.sampled); XCTAssertEqual(report.fresh, false); XCTAssertTrue(report.outputTruncated)
        XCTAssertTrue(report.notificationIssueTruncated); XCTAssertEqual(report.totalDevices, 256)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(report).count, 32768)
    }
}
