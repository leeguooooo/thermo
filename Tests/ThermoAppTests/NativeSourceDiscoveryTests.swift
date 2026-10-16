import AgentCore
@testable import CleanKit
import XCTest
@testable import ThermoApp

final class NativeSourceDiscoveryTests: XCTestCase {
    @MainActor func testIncompleteEmptyDiscoveryRetainsIssues() async throws {
        let model = NativeUpdatesModel(discovery: { _ in .init(sources: [], issues: [.init("unreadable", path: "/fixture")]) })
        model.load()
        for _ in 0..<100 where model.loading { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(model.loaded); XCTAssertFalse(try XCTUnwrap(model.discoveryReport).complete)
        XCTAssertTrue(model.sources.isEmpty); XCTAssertEqual(model.discoveryReport?.issues.count, 1)
    }
    @MainActor func testPartialDiscoveryStillAllowsIndependentCheckOfKnownSource() async throws {
        let source = NativeUpdateSource(app: .init(path: "/fixture/Known.app", name: "Known", bundleID: "com.example.known"), kind: "sparkle")
        let model = NativeUpdatesModel(discovery: { _ in .init(sources: [source], issues: [.init("unreadable", path: "/other")]) }, checker: {
            .init(source: $0, status: "noNewerCompatibleVersion", message: "fixture")
        })
        model.load()
        for _ in 0..<100 where model.loading { try await Task.sleep(nanoseconds: 10_000_000) }
        model.check(source)
        for _ in 0..<100 where model.results[source.id] == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.results[source.id]?.status, "noNewerCompatibleVersion")
        XCTAssertFalse(try XCTUnwrap(model.discoveryReport).complete)
    }
    private final class Reads: @unchecked Sendable {
        let lock = NSLock(); private var value = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    }
    @MainActor func testRetiredDiscoveryCannotPublishLateIssuesIntoFreshResult() async throws {
        let began = expectation(description: "old read"), release = DispatchSemaphore(value: 0), reads = Reads()
        defer { release.signal() }
        let model = NativeUpdatesModel(discovery: { _ in
            if reads.next() == 1 {
                began.fulfill(); _ = release.wait(timeout: .now() + 5)
                return .init(sources: [], issues: [.init("old issue", path: "/old")])
            }
            return .init(sources: [])
        })
        model.load(); await fulfillment(of: [began], timeout: 2)
        model.retire(); model.load(); release.signal()
        for _ in 0..<100 where model.loading { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(try XCTUnwrap(model.discoveryReport).complete)
        XCTAssertTrue(model.discoveryReport?.issues.isEmpty == true)
    }
}
