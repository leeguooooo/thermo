import Combine
import Foundation
import XCTest
@testable import PerformanceFeature

final class PanelSamplingTests: XCTestCase {
    private final class SlowPanel: @unchecked Sendable {
        let began = XCTestExpectation(description: "physical read began off main thread")
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var calls = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
        func read() -> PanelModel.Reading {
            XCTAssertFalse(Thread.isMainThread)
            lock.lock(); calls += 1; let call = calls; lock.unlock()
            if call == 1 { began.fulfill(); _ = release.wait(timeout: .now() + 15) }
            return .init(cpu: Double(call))
        }
    }

    @MainActor func testPanelSlowReadDoesNotBlockMainThreadOrPublishAfterHiding() async {
        let reader = SlowPanel()
        defer { reader.release.signal() }
        let panel = PanelModel(readBackground: { reader.read() }, holdPulse: {}, releasePulse: {})
        defer { panel.setActive(false) }
        let fresh = expectation(description: "reopened panel gets a fresh read after old read drains")
        var values: [Double] = []
        let observation = panel.$currentCPU.compactMap { $0 }.sink { value in
            values.append(value)
            if value == 2 { fresh.fulfill() }
        }
        panel.setActive(true)
        await fulfillment(of: [reader.began], timeout: 5)
        panel.setActive(false)
        panel.setActive(true)
        XCTAssertEqual(reader.count, 1)
        XCTAssertNil(panel.currentCPU)
        reader.release.signal()
        await fulfillment(of: [fresh], timeout: 5)
        XCTAssertEqual(values, [2])
        XCTAssertFalse(panel.sampleInFlight)
        withExtendedLifetime(observation) {}
    }
    @MainActor func testVisibilityAndRetirementBalanceOnlyThisPanelsPulseHolder() {
        var enabled = true, holders = 0, reads = 0
        let panel = PanelModel(readSample: { reads += 1; return .init(cpu: 5) },
                               holdPulse: { holders += 1 }, releasePulse: { holders -= 1 },
                               samplingAllowed: { enabled })
        defer { panel.setActive(false) }
        panel.setActive(true); panel.setActive(true)
        XCTAssertEqual(holders, 1); XCTAssertEqual(reads, 1)
        enabled = false
        panel.setActive(true); panel.setActive(true); panel.setActive(false)
        XCTAssertEqual(holders, 0); XCTAssertEqual(reads, 1)
        XCTAssertFalse(panel.samplingActive)
    }
    @MainActor func testPanelStopReleasesOnlyItsLeaseAndRejectsLateSampling() {
        var samples = 0, holders = 1 // A separate visible Overview owns its own lease.
        var reading = PanelModel.Reading(cpu: 70, gpu: 8, download: 100, upload: 25)
        let panel = PanelModel(readSample: { samples += 1; return reading },
                               holdPulse: { holders += 1 }, releasePulse: { holders -= 1 })
        panel.sample()
        XCTAssertEqual(samples, 0)
        panel.setActive(true); panel.setActive(true)
        XCTAssertTrue(panel.samplingActive)
        XCTAssertEqual(samples, 1); XCTAssertEqual(holders, 2)
        XCTAssertEqual(panel.currentCPU, 70); XCTAssertEqual(panel.currentGPU, 8)
        panel.setActive(false); panel.setActive(false)
        panel.sample() // A delayed callback must not restart hidden work.
        XCTAssertFalse(panel.samplingActive)
        XCTAssertEqual(samples, 1); XCTAssertEqual(holders, 1)
        XCTAssertNil(panel.currentCPU); XCTAssertNil(panel.currentGPU); XCTAssertNil(panel.currentDownload)
        XCTAssertEqual(panel.cpu, [70], "retained history must be separate from current values")
        reading = .init(gpu: .nan)
        panel.setActive(true)
        XCTAssertNil(panel.currentCPU); XCTAssertNil(panel.currentGPU)
        XCTAssertEqual(panel.cpu, [70])
        panel.setActive(false)
        XCTAssertEqual(holders, 1)
    }






}
