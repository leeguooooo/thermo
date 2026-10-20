import XCTest
@testable import AgentCore

final class AudioInputReportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1000)
    private func observation(_ count: Int = 1, name: String = "Microphone") -> AudioInputObservation {
        .init(clients: (0..<count).map { index in
            .init(objectID: UInt32(index + 10), process: .init(pid: Int32(index + 100), uid: 501,
                  started: Date(timeIntervalSince1970: 100), executable: "/Recorder\(index)"), bundleID: "test.recorder.\(index)",
                  devices: [.init(id: 1, uid: "private-hardware-uid", name: name)])
        }, sampled: now)
    }
    func testExportContainsUsefulClientMetadataAndOmitsHardwareUIDs() throws {
        let report = AudioInputReport(observation: observation(), source: "liveInspection", now: now)
        XCTAssertEqual(report.state, "active"); XCTAssertEqual(report.complete, true); XCTAssertEqual(report.fresh, true)
        XCTAssertEqual(report.clients.first?.appKey, "test.recorder.0")
        let data = try JSONEncoder().encode(report), text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("private-hardware-uid")); XCTAssertTrue(text.contains("Microphone"))
        XCTAssertFalse(report.recordsAudio)
    }
    func testUnknownStaleAndNotCollectedAreDistinctFromIdle() {
        XCTAssertEqual(AudioInputReport(observation: .init(available: false, sampled: now), source: "test", now: now).state, "unknown")
        XCTAssertEqual(AudioInputReport(observation: observation(), source: "test", now: now.addingTimeInterval(16)).state, "stale")
        let off = AudioInputReport(observation: nil, source: "appObserver", enabled: false)
        XCTAssertEqual(off.state, "notCollected"); XCTAssertNil(off.complete); XCTAssertNil(off.available)
        XCTAssertEqual(AudioInputReport(observation: nil, source: "appObserver", enabled: true).state, "checking")
        XCTAssertEqual(AudioInputReport(observation: .init(sampled: now), source: "test", now: now).state, "idle")
    }
    func testExplicitClientLimitPreservesFullCountsAndMarksLimitedOutput() {
        let report = AudioInputReport(observation: observation(3), source: "test", limit: 2, now: now)
        XCTAssertEqual(report.clients.count, 2); XCTAssertEqual(report.totalClients, 3)
        XCTAssertTrue(report.outputTruncated); XCTAssertEqual(report.complete, true)
    }
    func testLargeStatusFitsInsideControlFrameWithoutLosingTotalsOrCompletenessState() throws {
        let muted = Dictionary(uniqueKeysWithValues: (0..<100).map { (String(repeating: "x", count: 4000) + String($0), "App") })
        let report = AudioInputReport(observation: observation(10, name: String(repeating: "m", count: 10000)),
                                     source: "appObserver", muted: muted, byteBudget: 32768, now: now)
        XCTAssertTrue(report.outputTruncated); XCTAssertEqual(report.totalClients, 10); XCTAssertEqual(report.totalMutedApps, 100)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(report).count, 32768)
        let envelope = AppControlResponse(request: .init(action: "audio-input.status"), succeeded: true, audioInput: report)
        XCTAssertLessThan(try JSONEncoder().encode(envelope).count, AppControlTransport.limit)
    }
    func testOldControlResponseStillDecodesAndNewTypedReportRoundTrips() throws {
        let request = AppControlRequest(action: "status")
        let old = AppControlResponse(request: request, succeeded: true, values: ["appVersion":"old"])
        let legacy = try JSONEncoder().encode(old)
        XCTAssertFalse(String(decoding: legacy, as: UTF8.self).contains("audioInput"))
        XCTAssertNil(try JSONDecoder().decode(AppControlResponse.self, from: legacy).audioInput)
        let report = AudioInputReport(observation: observation(), source: "appObserver", now: now)
        let data = try JSONEncoder().encode(AppControlResponse(request: request, succeeded: true, audioInput: report))
        XCTAssertEqual(try JSONDecoder().decode(AppControlResponse.self, from: data).audioInput?.clients.first?.pid, 100)
    }
    func testNonFiniteDatesAndLargeNotificationIssueRemainEncodableAndUnconfirmed() throws {
        var value = observation(); value.sampled = Date(timeIntervalSinceReferenceDate: .nan)
        value.clients[0].process.started = Date(timeIntervalSinceReferenceDate: .nan)
        let report = AudioInputReport(observation: value, source: "test", notificationIssue: String(repeating: "🟠", count: 1000), now: now)
        XCTAssertNil(report.sampled); XCTAssertNil(report.clients.first?.processStarted)
        XCTAssertEqual(report.fresh, false); XCTAssertNotEqual(report.state, "idle")
        XCTAssertTrue(report.notificationIssueTruncated)
        XCTAssertTrue(report.outputTruncated)
        XCTAssertLessThanOrEqual(report.notificationIssue?.utf8.count ?? 0, 1027)
        XCTAssertNoThrow(try JSONEncoder().encode(report))
    }
}
