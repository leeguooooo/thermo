import AgentDoctor
import SwiftUI
import ThermoL10n

@MainActor final class ToolUsageModel: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var stopping = false
    @Published private(set) var report: ToolUsageReport?
    private var cancellation: DoctorCancellation?

    init(report: ToolUsageReport? = nil) { self.report = report }

    func analyze(encoding: TextEncoding = .heuristic) {
        guard !running else { return }
        let cancellation = DoctorCancellation()
        self.cancellation = cancellation
        running = true; stopping = false
        Task.detached(priority: .utility) {
            let report = AgentDoctor.usage(env: DoctorEnvironment(tokenEncoding: encoding, cancelled: { cancellation.isCancelled }))
            await MainActor.run {
                guard self.cancellation === cancellation else { return }
                self.report = report
                self.running = false; self.stopping = false; self.cancellation = nil
            }
        }
    }
    func stop() { guard running else { return }; stopping = true; cancellation?.cancel() }
}

struct ToolUsagePanel: View {
    @ObservedObject var model: ToolUsageModel
    let kind: String
    var encoding: TextEncoding = .heuristic
    @State private var sort = UsageSort.text
    @State private var visibleRowLimit = 8
    enum UsageSort: String, CaseIterable {
        case text, errors, time, calls
        var title: String {
            switch self {
            case .text: return tr("Returned text")
            case .errors: return tr("Explicit errors")
            case .time: return tr("Observed time")
            case .calls: return tr("Call count")
            }
        }
        func value(_ row: ToolUsageRow) -> Double {
            switch self {
            case .text: return row.referenceEncoding == nil ? Double(row.returnedTextEstimatedTokens) : row.referenceReturnedTextTokens.map(Double.init) ?? -1
            case .errors: return Double(row.reportedErrors)
            case .time: return row.totalObservedSeconds ?? -1
            case .calls: return Double(row.calls)
            }
        }
    }
    func seconds(_ value: Double?) -> String { value.map { String(format: "%.3f s", $0) } ?? tr("Unknown") }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(tr("Observed usage"), systemImage: "chart.bar.xaxis").font(.headline)
                Spacer()
                if model.running {
                    ProgressView().controlSize(.small)
                    Button(tr("Stop checking")) { model.stop() }.disabled(model.stopping)
                } else { Button(tr("Analyze local logs")) { model.analyze(encoding: encoding) } }
            }
            Text(tr("Reads local Claude/Codex logs for the last 7 days, across projects. Prompts, arguments and result text stay out of the report."))
                .font(.caption).foregroundStyle(.secondary)
            if let report = model.report {
                if report.referenceEncoding != (encoding == .heuristic ? nil : encoding.rawValue) {
                    Text(tr("The selected encoding differs from this report; analyze again to update counts.")).font(.caption).foregroundStyle(.orange)
                }
                if let encoding = report.referenceEncoding { Text(tr("Ordinary-text reference encoding: %1$@", encoding)).font(.caption).foregroundStyle(.secondary) }
                if model.running { Text(tr("Showing the previous analysis while refreshing…")).font(.caption).foregroundStyle(.secondary) }
                let rows = report.tools.filter { $0.kind == kind }.sorted {
                    sort.value($0) == sort.value($1) ? $0.id < $1.id : sort.value($0) > sort.value($1)
                }
                let textSummary = report.returnedTextSummary(kind: kind)
                Picker(tr("Sort observed usage"), selection: $sort) {
                    ForEach(UsageSort.allCases, id: \.self) { value in Text(value.title).tag(value) }
                }.pickerStyle(.segmented)
                Text(report.complete ? tr("Log reading complete within the selected scope") : tr("Partial log coverage"))
                    .font(.subheadline.weight(.medium))
                Text(tr("%1$@ files · %2$@ clipped · %3$@ malformed lines · %4$@ other tool calls", String(report.coverage.filesRead), String(report.coverage.clippedFiles), String(report.coverage.malformedLines), String(report.coverage.otherToolCalls)))
                    .font(.caption).foregroundStyle(.secondary)
                Text(report.generated, style: .time).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text(report.since, style: .date); Text("–"); Text(report.until, style: .date)
                }.font(.caption).foregroundStyle(.secondary)
                if report.coverage.cancelled { Text(tr("Analysis stopped; partial results are shown.")).font(.caption).foregroundStyle(.orange) }
                if report.coverage.limitReached { Text(tr("A log scan limit was reached; results are partial.")).font(.caption).foregroundStyle(.orange) }
                if report.coverage.unreadableFiles > 0 || report.coverage.unmatchedResults > 0 {
                    Text(tr("%1$@ unreadable files · %2$@ results without a matching call", String(report.coverage.unreadableFiles), String(report.coverage.unmatchedResults)))
                        .font(.caption).foregroundStyle(.orange)
                }
                Text(tr("Missing timestamps %1$@ · unsupported usage records %2$@", String(report.coverage.missingTimestamps), String(report.coverage.unsupportedUsageRecords)))
                    .font(.caption).foregroundStyle(.secondary)
                if report.coverage.oversizedLines > 0 {
                    Text(tr("%1$@ oversized log lines were skipped; returned text totals may be incomplete.", String(report.coverage.oversizedLines))).font(.caption).foregroundStyle(.orange)
                }
                if rows.isEmpty {
                    Text(tr("No directly attributable calls were observed. This does not prove the tool or Skill was unused."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !rows.isEmpty {
                    Text(tr("Returned text total in this category: %1$@ bytes / %2$@ tokens",
                            textSummary.returnedTextBytes.map(String.init) ?? tr("Unknown"),
                            textSummary.returnedTextTokens.map { (report.referenceEncoding == nil ? "≈" : "") + String($0) } ?? tr("Unknown")))
                        .font(.caption.monospaced())
                    Text(tr("Totals include all observed entries in this category, including hidden rows. Missing logs, results and non-text content are not included; this is not request usage."))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(tr("Showing %1$@ of %2$@ entries", String(min(visibleRowLimit, rows.count)), String(rows.count)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(rows.prefix(visibleRowLimit))) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text((row.server.map { $0 + " / " } ?? "") + row.name + " · " + row.host)
                            .font(.subheadline.weight(.medium)).textSelection(.enabled)
                        Text(tr("%1$@ calls · %2$@ results · %3$@ explicit errors · %4$@ unknown error status · %5$@ missing results",
                                String(row.calls), String(row.completed), String(row.reportedErrors), String(row.unknownErrorStatus), String(row.missingResults)))
                            .font(.caption)
                        if let rate = row.explicitErrorRate, let denominator = row.knownStatusResults {
                            Text(tr("Explicit errors among known-status results: %1$@ / %2$@ (%3$@)", String(row.reportedErrors), String(denominator), String(format: "%.1f%%", rate * 100)))
                                .font(.caption)
                        } else {
                            Text(tr("Explicit error rate unknown; no usable known-status denominator."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(tr("Returned text %1$@ bytes / ≈%2$@ tokens · median %3$@ · P95 %4$@ · observed sum %5$@",
                                String(row.returnedTextBytes), String(row.returnedTextEstimatedTokens), seconds(row.medianSeconds), seconds(row.p95Seconds), seconds(row.totalObservedSeconds)))
                            .font(.caption.monospaced()).textSelection(.enabled)
                            .help(tr("P95 is shown only with at least 20 valid timing samples."))
                        if let encoding = row.referenceEncoding {
                            Text(tr("%1$@ reference text tokens: %2$@ · %3$@ results unavailable", encoding, row.referenceReturnedTextTokens.map(String.init) ?? tr("Unknown"), String(row.unavailableReferenceResults ?? 0))).font(.caption.monospaced())
                        }
                        if let percentage = textSummary.percentage(of: row) {
                            Text(tr("Share of this category's observed returned-text tokens: %1$@", String(format: "%.1f%%", percentage)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if row.nonTextBlocks > 0 {
                            Text(tr("%1$@ non-text result blocks were not tokenized.", String(row.nonTextBlocks))).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if visibleRowLimit < rows.count {
                    Button(tr("Show more entries")) { visibleRowLimit = min(rows.count, visibleRowLimit + 8) }
                }
                if !rows.isEmpty {
                    Text(ToolUsageReport.errorStatusExplanation)
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !report.sessionTokens.isEmpty {
                    Text(tr("Request counters, not individual tool consumption")).font(.subheadline.weight(.medium))
                    ForEach(report.sessionTokens, id: \.host) { usage in
                        Text(tr("%1$@: %2$@ requests · input %3$@ · output %4$@ tokens", usage.host, String(usage.requests), String(usage.inputTokens), String(usage.outputTokens)))
                            .font(.caption.monospaced())
                        Text(tr("Cached input %1$@ · cache creation %2$@; raw counters are not added to input.", usage.cachedInputTokens.map(String.init) ?? tr("Unknown"), usage.cacheWriteInputTokens.map(String.init) ?? tr("Unknown")))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(tr("No supported request token records were found; request usage is unknown.")).font(.caption).foregroundStyle(.secondary)
                }
                Text(report.note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(18).glass()
        .onChange(of: sort) { _ in visibleRowLimit = 8 }
        .onChange(of: kind) { _ in visibleRowLimit = 8 }
        .onChange(of: model.report?.generated) { _ in visibleRowLimit = 8 }
    }
}
