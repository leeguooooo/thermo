import XCTest
@testable import ThermoApp

final class TaskComparisonModelTests: XCTestCase {
    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/examples/task-comparison.json")
    }
    @MainActor private func waitForIdle(_ model: TaskComparisonModel) async throws {
        for _ in 0..<200 {
            if !model.loading { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Evaluation import did not finish")
    }
    @MainActor func testValidImportAndFailedReplacementDoNotKeepStaleResults() async throws {
        let model = TaskComparisonModel()
        model.load(fixtureURL)
        try await waitForIdle(model)
        XCTAssertEqual(model.report?.kind, "skill")
        XCTAssertEqual(model.report?.matchedPairs, 3)
        XCTAssertNil(model.error)
        model.load(fixtureURL.deletingLastPathComponent().appendingPathComponent("does-not-exist.json"))
        XCTAssertNil(model.report)
        try await waitForIdle(model)
        XCTAssertNil(model.report)
        XCTAssertEqual(model.error, "Cannot open local evaluation file")
        model.clear()
        XCTAssertNil(model.error)
        XCTAssertNil(model.report)
    }
    @MainActor func testFailedEnvironmentImportKeepsReportedPassesButSuppressesComparisons() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        var runs = try XCTUnwrap(object["runs"] as? [[String: Any]])
        for index in runs.indices { runs[index]["comparisonCheck"] = "failed" }
        object["runs"] = runs
        let url = directory.appendingPathComponent("failed-checks.json")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let model = TaskComparisonModel()
        model.load(url)
        try await waitForIdle(model)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.report?.reportedBaseline.passed, 2)
        XCTAssertEqual(model.report?.reportedCandidate.timeout, 1)
        XCTAssertEqual(model.report?.comparisonCheckFailedRuns, 6)
        XCTAssertEqual(model.report?.matchedPairs, 0)
        XCTAssertNil(model.report?.passRateDifferencePercentagePoints)
        XCTAssertEqual(model.report?.inputTokens.samples, 0)
    }
    @MainActor func testClearingPendingImportPreventsLateResultFromReappearing() async throws {
        let model = TaskComparisonModel()
        model.load(fixtureURL)
        model.clear()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(model.loading)
        XCTAssertNil(model.report)
        XCTAssertNil(model.error)
    }
    @MainActor func testNewImportAfterClearWinsOverPendingImport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        object["kind"] = "mcp"
        let url = directory.appendingPathComponent("mcp.json")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let model = TaskComparisonModel()
        model.load(fixtureURL)
        model.clear()
        model.load(url)
        try await waitForIdle(model)
        XCTAssertEqual(model.report?.kind, "mcp")
        XCTAssertNil(model.error)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(model.report?.kind, "mcp")
    }
}
