import Foundation

/// Explicit, local evaluation records. No task execution or outcome inference from logs.
public enum TaskComparison {
    public enum Variant: String, Codable { case baseline, candidate }
    public enum Outcome: String, Codable { case passed, failed, timeout, error, unverified }
    public struct Conditions: Codable, Equatable {
        public var model: String
        public var environment: String
        public var settings: String
        public var task: String
        public var verifier: String
    }
    public struct Run: Codable {
        public var taskID: String
        public var repetition: Int
        public var variant: Variant
        public var conditions: Conditions
        public var outcome: Outcome
        public var seconds: Double?
        /// Native request counters only; input semantics must be identical across a pair.
        public var inputTokens: Int?
        public var outputTokens: Int?
        public var tokenSemantics: String?
    }
    public struct Records: Codable {
        public var schemaVersion: Int
        public var evidenceKind: String
        public var kind: String
        public var baselineRevision: String
        public var candidateRevision: String
        public var runs: [Run]
    }
    public struct Outcomes: Codable {
        public var passed = 0
        public var failed = 0
        public var timeout = 0
        public var error = 0
        public var unverified = 0
        mutating func add(_ outcome: Outcome) {
            switch outcome {
            case .passed: passed += 1
            case .failed: failed += 1
            case .timeout: timeout += 1
            case .error: error += 1
            case .unverified: unverified += 1
            }
        }
    }
    public struct Delta: Codable {
        public var samples: Int
        public var medianCandidateMinusBaseline: Double?
        public var minimumCandidateMinusBaseline: Double?
        public var maximumCandidateMinusBaseline: Double?
    }
    public struct Exclusion: Codable {
        public var taskID: String
        public var repetition: Int
        public var reason: String
    }
    public struct Report: Codable {
        public var schemaVersion = 1
        public var evidenceKind: String
        public var kind: String
        public var model: String
        public var environment: String
        public var settings: String
        public var baselineRevision: String
        public var candidateRevision: String
        public var totalRuns: Int
        public var matchedPairs: Int
        public var matchedTasks: Int
        public var verifiedOutcomePairs: Int
        public var tokenSemanticsMismatchPairs: Int
        public var baseline: Outcomes
        public var candidate: Outcomes
        public var bothPassed: Int
        public var candidateOnlyPassed: Int
        public var baselineOnlyPassed: Int
        public var neitherPassed: Int
        public var passRateDifferencePercentagePoints: Double?
        public var seconds: Delta
        public var inputTokens: Delta
        public var outputTokens: Delta
        public var excluded: [Exclusion]
        public var note: String
    }
    public struct InvalidRecords: Error, CustomStringConvertible {
        public let description: String
    }
    static func reject(_ message: String) -> InvalidRecords { InvalidRecords(description: message) }
    static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 58, 95].contains($0)
        }
    }
    static func digest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func delta(_ values: [Double]) -> Delta {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return Delta(samples: 0) }
        let center = sorted.count / 2
        let median = sorted.count % 2 == 1 ? sorted[center] : sorted[center - 1] / 2 + sorted[center] / 2
        return Delta(samples: sorted.count, medianCandidateMinusBaseline: median,
                     minimumCandidateMinusBaseline: sorted.first, maximumCandidateMinusBaseline: sorted.last)
    }

    /// Caller-supplied metadata is checked for consistency, not independently authenticated.
    public static func compare(_ data: Data) throws -> Report {
        guard data.count <= 4 * 1024 * 1024 else { throw reject("Evaluation file exceeds 4 MiB") }
        let records: Records
        do { records = try JSONDecoder().decode(Records.self, from: data) }
        catch { throw reject("Invalid evaluation JSON; see docs/ai-task-comparison.md") }
        guard records.schemaVersion == 1, ["synthetic", "measured"].contains(records.evidenceKind), ["skill", "mcp"].contains(records.kind),
              records.baselineRevision == "none" || digest(records.baselineRevision), digest(records.candidateRevision),
              !records.runs.isEmpty, records.runs.count <= 10_000 else { throw reject("Invalid evaluation header or run count") }
        var pairs: [String: [Variant: Run]] = [:]
        let reference = records.runs[0].conditions
        for run in records.runs {
            guard identifier(run.taskID), (1...1_000_000).contains(run.repetition), identifier(run.conditions.model),
                  [run.conditions.environment, run.conditions.settings, run.conditions.task, run.conditions.verifier].allSatisfy(digest),
                  run.seconds.map({ $0.isFinite && $0 >= 0 && $0 <= 31_536_000 }) ?? true,
                  run.inputTokens.map({ $0 >= 0 && $0 <= 1_000_000_000_000 }) ?? true,
                  run.outputTokens.map({ $0 >= 0 && $0 <= 1_000_000_000_000 }) ?? true,
                  run.tokenSemantics.map(identifier) ?? true,
                  (run.inputTokens == nil && run.outputTokens == nil) || run.tokenSemantics != nil else {
                throw reject("Invalid run metadata, metrics or token accounting declaration")
            }
            guard run.conditions.model == reference.model, run.conditions.environment == reference.environment,
                  run.conditions.settings == reference.settings else {
                throw reject("Mixed model, environment or settings; compare separate cohorts instead")
            }
            let key = "\(run.taskID)/\(run.repetition)"
            guard pairs[key]?[run.variant] == nil else { throw reject("Duplicate task/repetition/variant; refusing to choose a result") }
            pairs[key, default: [:]][run.variant] = run
        }
        var baseline = Outcomes(), candidate = Outcomes(), excluded: [Exclusion] = []
        var matched = 0, verified = 0, both = 0, wins = 0, losses = 0, neither = 0, tokenMismatch = 0
        var seconds: [Double] = [], input: [Double] = [], output: [Double] = []
        var taskDefinitions: [String: [String]] = [:]
        for key in pairs.keys.sorted() {
            let pair = pairs[key]!
            let representative = pair[.baseline] ?? pair[.candidate]!
            guard let b = pair[.baseline], let c = pair[.candidate] else {
                excluded.append(Exclusion(taskID: representative.taskID, repetition: representative.repetition, reason: "missing_variant")); continue
            }
            guard b.conditions == c.conditions else {
                excluded.append(Exclusion(taskID: b.taskID, repetition: b.repetition, reason: "conditions_mismatch")); continue
            }
            let definition = [b.conditions.task, b.conditions.verifier]
            guard taskDefinitions[b.taskID] == nil || taskDefinitions[b.taskID] == definition else {
                throw reject("Task or verifier changed across repetitions; use separate task IDs")
            }
            taskDefinitions[b.taskID] = definition
            matched += 1
            baseline.add(b.outcome); candidate.add(c.outcome)
            if b.outcome != .unverified && c.outcome != .unverified {
                verified += 1
                switch (b.outcome == .passed, c.outcome == .passed) {
                case (true, true): both += 1
                case (false, true): wins += 1
                case (true, false): losses += 1
                case (false, false): neither += 1
                }
            }
            // All matched outcomes participate, including failures/timeouts. Missing values stay missing.
            if let b = b.seconds, let c = c.seconds { seconds.append(c - b) }
            if let semantics = b.tokenSemantics, semantics == c.tokenSemantics {
                if let b = b.inputTokens, let c = c.inputTokens { input.append(Double(c) - Double(b)) }
                if let b = b.outputTokens, let c = c.outputTokens { output.append(Double(c) - Double(b)) }
            } else if let b = b.tokenSemantics, let c = c.tokenSemantics, b != c {
                tokenMismatch += 1
            }
        }
        return Report(evidenceKind: records.evidenceKind, kind: records.kind, model: reference.model, environment: reference.environment, settings: reference.settings,
                      baselineRevision: records.baselineRevision, candidateRevision: records.candidateRevision,
                      totalRuns: records.runs.count, matchedPairs: matched, matchedTasks: taskDefinitions.count,
                      verifiedOutcomePairs: verified, tokenSemanticsMismatchPairs: tokenMismatch,
                      baseline: baseline, candidate: candidate, bothPassed: both, candidateOnlyPassed: wins,
                      baselineOnlyPassed: losses, neitherPassed: neither,
                      passRateDifferencePercentagePoints: verified > 0 ? Double(wins - losses) * 100 / Double(verified) : nil,
                      seconds: delta(seconds), inputTokens: delta(input), outputTokens: delta(output), excluded: excluded,
                      note: "Declared local evaluation records only. Outcome checks and conditions are supplied by the evaluator, not verified by Thermo. Deltas are paired candidate minus baseline, include unsuccessful runs when measured, and are descriptive rather than a causal or significance claim. Missing metrics stay unknown. Request tokens are never allocated to individual tools; token semantics must match. No task, script, verifier or network request is executed.")
    }
}
