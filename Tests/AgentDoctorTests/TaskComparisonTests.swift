import XCTest
@testable import AgentDoctor

final class TaskComparisonTests: XCTestCase {
    private func fixture() throws -> TaskComparison.Records {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(TaskComparison.Records.self, from: Data(contentsOf: root.appendingPathComponent("docs/examples/task-comparison.json")))
    }
    private func compare(_ records: TaskComparison.Records) throws -> TaskComparison.Report {
        try TaskComparison.compare(JSONEncoder().encode(records))
    }
    func testPairedResultsRetainFailureAndTimeoutRatherThanRewardingOnlySuccesses() throws {
        let report = try compare(fixture())
        XCTAssertEqual(report.evidenceKind, "synthetic")
        XCTAssertEqual(report.matchedPairs, 3)
        XCTAssertEqual(report.matchedTasks, 1)
        XCTAssertEqual(report.verifiedOutcomePairs, 3)
        XCTAssertEqual(report.baseline.failed, 1)
        XCTAssertEqual(report.candidate.timeout, 1)
        XCTAssertEqual(report.bothPassed, 1)
        XCTAssertEqual(report.candidateOnlyPassed, 1)
        XCTAssertEqual(report.baselineOnlyPassed, 1)
        XCTAssertEqual(report.passRateDifferencePercentagePoints, 0)
        XCTAssertEqual(report.seconds.samples, 3)
        XCTAssertEqual(report.seconds.medianCandidateMinusBaseline, 2)
        XCTAssertEqual(report.seconds.minimumCandidateMinusBaseline, -2)
        XCTAssertEqual(report.seconds.maximumCandidateMinusBaseline, 24)
        XCTAssertEqual(report.inputTokens.samples, 2)
        XCTAssertEqual(report.inputTokens.medianCandidateMinusBaseline, 35)
        XCTAssertEqual(report.outputTokens.medianCandidateMinusBaseline, -15)
    }
    func testUnverifiedDoesNotCountAsFailureOrSuccessButTimingIsStillObserved() throws {
        var records = try fixture()
        records.runs[1].outcome = .unverified
        let report = try compare(records)
        XCTAssertEqual(report.matchedPairs, 3)
        XCTAssertEqual(report.candidate.unverified, 1)
        XCTAssertEqual(report.verifiedOutcomePairs, 2)
        XCTAssertEqual(report.bothPassed, 0)
        XCTAssertEqual(report.seconds.samples, 3)
    }
    func testNeitherPassedAndExplicitErrorsRemainInVerifiedDenominator() throws {
        var records = try fixture()
        records.runs[0].outcome = .failed
        records.runs[1].outcome = .error
        let report = try compare(records)
        XCTAssertEqual(report.verifiedOutcomePairs, 3)
        XCTAssertEqual(report.candidate.error, 1)
        XCTAssertEqual(report.neitherPassed, 1)
        XCTAssertEqual(report.bothPassed, 0)
        XCTAssertEqual(report.passRateDifferencePercentagePoints, 0)
    }
    func testMissingPairsAndChangedTaskOrVerifierAreExcludedWithEvidence() throws {
        var records = try fixture()
        records.runs.removeLast()
        records.runs[1].conditions.task = String(repeating: "f", count: 64)
        records.runs[3].conditions.verifier = String(repeating: "e", count: 64)
        let report = try compare(records)
        XCTAssertEqual(report.totalRuns, 5)
        XCTAssertEqual(report.matchedPairs, 0)
        XCTAssertEqual(report.excluded.map(\.reason), ["conditions_mismatch", "conditions_mismatch", "missing_variant"])
        XCTAssertNil(report.passRateDifferencePercentagePoints)
        XCTAssertNil(report.inputTokens.medianCandidateMinusBaseline)
    }
    func testDuplicateOrMixedCohortsAreRejectedRatherThanSelectedOrPooled() throws {
        var records = try fixture()
        records.runs.append(records.runs[0])
        XCTAssertThrowsError(try compare(records))
        for field in ["model", "environment", "settings"] {
            records = try fixture()
            switch field {
            case "model": records.runs[0].conditions.model = "different-model"
            case "environment": records.runs[0].conditions.environment = String(repeating: "f", count: 64)
            default: records.runs[0].conditions.settings = String(repeating: "e", count: 64)
            }
            XCTAssertThrowsError(try compare(records))
        }
        records = try fixture()
        for index in [2, 3] { records.runs[index].conditions.task = String(repeating: "f", count: 64) }
        XCTAssertThrowsError(try compare(records))
    }
    func testUnknownMetricsAndMismatchedAccountingCannotBecomeZeroOrSavings() throws {
        var records = try fixture()
        records.runs[1].tokenSemantics = "different-native-semantics"
        records.runs[3].seconds = nil
        let report = try compare(records)
        XCTAssertEqual(report.inputTokens.samples, 1)
        XCTAssertEqual(report.inputTokens.medianCandidateMinusBaseline, 20)
        XCTAssertEqual(report.tokenSemanticsMismatchPairs, 1)
        XCTAssertEqual(report.seconds.samples, 2)
        for index in records.runs.indices {
            records.runs[index].inputTokens = nil
            records.runs[index].outputTokens = nil
            records.runs[index].seconds = nil
        }
        let missing = try compare(records)
        XCTAssertEqual(missing.inputTokens.samples, 0)
        XCTAssertNil(missing.inputTokens.medianCandidateMinusBaseline)
        XCTAssertNil(missing.seconds.medianCandidateMinusBaseline)
    }
    func testFailedPostRunCheckCannotBecomeSavingsDespiteIdenticalConditionsAndPassedTask() throws {
        var records = try fixture()
        records.runs[0].comparisonCheck = .failed
        records.runs[1].outcome = .passed
        records.runs[1].seconds = 0
        let report = try compare(records)
        XCTAssertEqual(report.totalRuns, 6)
        XCTAssertEqual(report.matchedPairs, 2)
        XCTAssertEqual(report.excluded.first?.reason, "comparison_check_failed")
        XCTAssertEqual(report.excluded.first?.baselineOutcome, .passed)
        XCTAssertEqual(report.excluded.first?.candidateOutcome, .passed)
        XCTAssertEqual(report.reportedBaseline.passed, 2)
        XCTAssertEqual(report.reportedCandidate.passed, 2)
        XCTAssertEqual(report.baseline.passed, 1)
        XCTAssertEqual(report.comparisonCheckFailedRuns, 1)
        XCTAssertEqual(report.comparisonCheckUnverifiedRuns, 0)
        XCTAssertEqual(report.seconds.samples, 2)
        XCTAssertEqual(report.seconds.minimumCandidateMinusBaseline, 2)
        XCTAssertEqual(report.inputTokens.samples, 1)
        XCTAssertEqual(report.verifiedOutcomePairs, 2)
    }
    func testUnknownAndMissingPostRunChecksPreserveAllOutcomesWithoutAnyComparison() throws {
        var records = try fixture()
        for index in records.runs.indices { records.runs[index].comparisonCheck = .unverified }
        var report = try compare(records)
        XCTAssertEqual(report.matchedPairs, 0)
        XCTAssertEqual(report.matchedTasks, 0)
        XCTAssertEqual(report.reportedBaseline.failed, 1)
        XCTAssertEqual(report.reportedCandidate.timeout, 1)
        XCTAssertEqual(report.comparisonCheckUnverifiedRuns, 6)
        XCTAssertTrue(report.excluded.allSatisfy { $0.reason == "comparison_check_unverified" })
        XCTAssertNil(report.passRateDifferencePercentagePoints)
        XCTAssertNil(report.seconds.medianCandidateMinusBaseline)
        XCTAssertEqual(report.inputTokens.samples, 0)
        records.schemaVersion = 1
        for index in records.runs.indices { records.runs[index].comparisonCheck = nil }
        report = try compare(records)
        XCTAssertEqual(report.matchedPairs, 0)
        XCTAssertEqual(report.comparisonCheckUnverifiedRuns, 6)
        XCTAssertEqual(report.reportedBaseline.passed, 2)
        XCTAssertEqual(report.reportedCandidate.timeout, 1)
    }
    func testVersionTwoRequiresExplicitChecksAndInvalidEnumIsNotIgnored() throws {
        var records = try fixture()
        records.runs[0].comparisonCheck = nil
        XCTAssertThrowsError(try compare(records))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(try fixture())) as? [String: Any])
        var runs = try XCTUnwrap(object["runs"] as? [[String: Any]])
        runs[0]["comparisonCheck"] = "PRIVATE_UNRECOGNIZED_CHECK"
        object["runs"] = runs
        XCTAssertThrowsError(try TaskComparison.compare(JSONSerialization.data(withJSONObject: object))) { error in
            XCTAssertFalse(String(describing: error).contains("PRIVATE_UNRECOGNIZED_CHECK"))
        }
    }
    func testMissingVariantRetainsItsReportedOutcome() throws {
        var records = try fixture()
        records.runs.removeLast()
        let report = try compare(records)
        XCTAssertEqual(report.excluded.last?.reason, "missing_variant")
        XCTAssertEqual(report.excluded.last?.baselineOutcome, .passed)
        XCTAssertNil(report.excluded.last?.candidateOutcome)
        XCTAssertEqual(report.reportedBaseline.passed, 2)
        XCTAssertEqual(report.reportedCandidate.passed, 2)
    }
    func testInvalidLimitsAndSensitiveFreeTextAreRejectedWithoutEchoingIt() throws {
        var records = try fixture()
        records.runs[0].taskID = "private prompt / absolute path"
        XCTAssertThrowsError(try compare(records)) { error in
            XCTAssertFalse(String(describing: error).contains("private prompt"))
        }
        records = try fixture(); records.runs[0].inputTokens = -1
        XCTAssertThrowsError(try compare(records))
        records = try fixture(); records.runs[0].seconds = -1
        XCTAssertThrowsError(try compare(records))
        records = try fixture(); records.runs[0].tokenSemantics = nil
        XCTAssertThrowsError(try compare(records))
        records = try fixture(); records.schemaVersion = 3
        XCTAssertThrowsError(try compare(records))
        records = try fixture(); records.runs = []
        XCTAssertThrowsError(try compare(records))
        XCTAssertThrowsError(try TaskComparison.compare(Data(repeating: 32, count: 4 * 1024 * 1024 + 1)))
        XCTAssertThrowsError(try TaskComparison.compare(Data("{\"secret\": broken}".utf8))) { error in
            XCTAssertFalse(String(describing: error).contains("secret"))
        }
    }
}
