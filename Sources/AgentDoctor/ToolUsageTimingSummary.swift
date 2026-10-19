import Foundation
import ThermoL10n

/// Union of valid, fully observed intervals in one category, never task or CPU time.
/// Only aggregates leave the parser; no call timestamps or identifiers are exported.
public struct ToolUsageTimingSummary: Codable, Equatable, Sendable {
    public var kind: String
    public var calls: Int
    public var timingSamples: Int
    public var callsWithoutUsableTiming: Int
    public var summedObservedSeconds: Double?
    public var occupiedObservedSeconds: Double?

    public var isConsistent: Bool {
        guard ["mcp", "skill", "outer"].contains(kind), calls >= 0, timingSamples >= 0,
              timingSamples <= calls, callsWithoutUsableTiming == calls - timingSamples else { return false }
        if timingSamples == 0 { return summedObservedSeconds == nil && occupiedObservedSeconds == nil }
        guard let sum = summedObservedSeconds, let occupied = occupiedObservedSeconds,
              sum.isFinite, occupied.isFinite, sum >= 0, occupied >= 0 else { return false }
        return occupied <= sum + max(1e-9, sum * 1e-12)
    }

    public var displayLines: [String] {
        guard isConsistent else { return [Self.unavailableExplanation] }
        func seconds(_ value: Double?) -> String { value.map { String(format: "%.3f s", $0) } ?? tr("Unknown") }
        return [tr("Observed occupied time %1$@ · summed call intervals %2$@", seconds(occupiedObservedSeconds), seconds(summedObservedSeconds)),
                tr("%1$@ / %2$@ selected calls have valid start/end pairs · %3$@ calls without usable timing", String(timingSamples), String(calls), String(callsWithoutUsableTiming))]
    }

    public static var unavailableExplanation: String {
        tr("Overlap-adjusted timing is unavailable or inconsistent; analyze again.")
    }
    public static var explanation: String {
        tr("Occupied time counts overlapping observed intervals once and excludes gaps. Only fully observed pairs within the window count; categories stay separate. Not CPU time, task duration or billing.")
    }
}

extension ToolUsageReport {
    public func timingSummary(kind: String) -> ToolUsageTimingSummary? {
        guard let summaries = timingSummaries else { return nil }
        let matched = summaries.filter { $0.kind == kind }
        guard matched.count == 1, matched[0].isConsistent else { return nil }
        let rows = kind == "outer" ? (coverage.unattributedResults?.byTool ?? []) : tools.filter { $0.kind == kind }
        func total(_ field: KeyPath<ToolUsageRow, Int>) -> Int? {
            var sum = 0
            for row in rows {
                let value = row[keyPath: field], next = sum.addingReportingOverflow(row[keyPath: field])
                guard value >= 0, !next.overflow else { return nil }
                sum = next.partialValue
            }
            return sum
        }
        guard total(\.calls) == matched[0].calls, total(\.timingSamples) == matched[0].timingSamples else { return nil }
        let window = until.timeIntervalSince(since)
        guard window.isFinite, window >= 0 else { return nil }
        if let occupied = matched[0].occupiedObservedSeconds, occupied > window + max(1e-9, window * 1e-12) { return nil }
        return matched[0]
    }
}

struct ToolUsageTimingAccumulator {
    var calls = 0
    private var intervals: [(start: Double, end: Double)] = []

    mutating func observe(start: Date?, end: Date?) {
        calls += 1
        guard let start, let end else { return }
        let lower = start.timeIntervalSinceReferenceDate, upper = end.timeIntervalSinceReferenceDate
        guard lower.isFinite, upper.isFinite, upper >= lower, (upper - lower).isFinite else { return }
        intervals.append((lower, upper))
    }

    func summary(kind: String) -> ToolUsageTimingSummary {
        let sorted = intervals.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        var sum = 0.0, occupied = 0.0
        var current: (start: Double, end: Double)?
        for interval in sorted {
            sum += interval.end - interval.start
            if let previous = current {
                if interval.start <= previous.end { current = (previous.start, max(previous.end, interval.end)) }
                else { occupied += previous.end - previous.start; current = interval }
            } else { current = interval }
        }
        if let current { occupied += current.end - current.start }
        let valid = !sorted.isEmpty && sum.isFinite && occupied.isFinite
        return ToolUsageTimingSummary(kind: kind, calls: calls, timingSamples: sorted.count,
            callsWithoutUsableTiming: calls - sorted.count, summedObservedSeconds: valid ? sum : nil,
            occupiedObservedSeconds: valid ? occupied : nil)
    }
}
