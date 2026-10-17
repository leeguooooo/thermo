import AgentDoctor
import AppKit
import SwiftUI
import ThermoL10n

@MainActor final class ToolUsageModel: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var stopping = false
    @Published private(set) var report: ToolUsageReport?
    private var cancellation: DoctorCancellation?

    init(report: ToolUsageReport? = nil) { self.report = report }

    func analyze(encoding: TextEncoding = .heuristic, logFile: URL? = nil, host: String? = nil) {
        guard !running else { return }
        let cancellation = DoctorCancellation()
        self.cancellation = cancellation
        running = true; stopping = false
        Task.detached(priority: .utility) {
            let report = AgentDoctor.usage(host: host, logFile: logFile, env: DoctorEnvironment(tokenEncoding: encoding, cancelled: { cancellation.isCancelled }))
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
    @State private var sort: UsageSort
    @State private var visibleRowLimit = 8
    init(model: ToolUsageModel, kind: String, encoding: TextEncoding = .heuristic) {
        self.model = model; self.kind = kind; self.encoding = encoding
        _sort = State(initialValue: kind == "skill" ? .instructions : .text)
    }
    enum UsageSort: String, CaseIterable {
        case text, instructions, errors, time, calls
        var title: String {
            switch self {
            case .text: return tr("Returned text")
            case .instructions: return tr("Loaded instructions")
            case .errors: return tr("Explicit errors")
            case .time: return tr("Observed time")
            case .calls: return tr("Call count")
            }
        }
        func value(_ row: ToolUsageRow) -> Double {
            switch self {
            case .text: return row.referenceEncoding == nil ? Double(row.returnedTextEstimatedTokens) : row.referenceReturnedTextTokens.map(Double.init) ?? -1
            case .instructions:
                return row.observedInstructionTokens.map(Double.init) ?? -1
            case .errors: return Double(row.reportedErrors) + Double(row.invocationFailures ?? 0)
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
                } else {
                    Button(tr("Analyze local logs")) { model.analyze(encoding: encoding) }
                    Menu(tr("Analyze one log…")) {
                        Button(tr("Claude session log…")) { chooseLog(host: "claude") }
                        Button(tr("Codex session log…")) { chooseLog(host: "codex") }
                    }.fixedSize()
                }
            }
            Text(model.report?.singleLogFile == true
                 ? tr("Only the selected session log is read, from its beginning within the scan budget. Event time filters still apply; the file path, prompts, arguments and result text stay out of the report.")
                 : tr("Reads local Claude/Codex logs for the last 7 days, across projects. Prompts, arguments and result text stay out of the report."))
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
                    ForEach(UsageSort.allCases.filter { kind == "skill" || $0 != .instructions }, id: \.self) { value in Text(value.title).tag(value) }
                }.pickerStyle(.segmented)
                if kind == "skill" {
                    instructionUsage(report.observedSkillInstructions, encoding: report.referenceEncoding)
                    Text(tr("Only explicitly source-linked Claude instruction messages are measured. Kept separate from tool replies and request counters; missing loads, referenced files and billing remain unknown."))
                        .font(.caption).foregroundStyle(.secondary)
                    if let unmatched = report.coverage.unmatchedInstructionEvents, unmatched > 0 {
                        Text(tr("%1$@ instruction metadata records could not be linked or identified.", String(unmatched)))
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Text(report.complete ? tr("Log reading complete within the selected scope") : tr("Partial log coverage"))
                    .font(.subheadline.weight(.medium))
                Text(tr("Read %1$@ / %2$@ discovered log files · %3$@ bytes", String(report.coverage.filesRead), String(report.coverage.filesDiscovered), String(report.coverage.bytesRead)))
                    .font(.caption).foregroundStyle(.secondary)
                Text(tr("%1$@ clipped files · %2$@ malformed lines · %3$@ other tool calls", String(report.coverage.clippedFiles), String(report.coverage.malformedLines), String(report.coverage.otherToolCalls)))
                    .font(.caption).foregroundStyle(.secondary)
                if !report.complete {
                    Text(tr("Rankings cover only the logs read; unread logs may change the order."))
                        .font(.caption).foregroundStyle(.orange)
                }
                if let other = report.coverage.unattributedResults, report.coverage.otherToolCalls > 0 {
                    Text(tr("Unattributed tool results: %1$@ returned · %2$@ missing · %3$@ unmeasured", String(other.completed), String(other.missingResults), String(other.unmeasuredResults)))
                        .font(.caption).foregroundStyle(.secondary)
                    let tokens = report.referenceEncoding == nil ? "≈\(other.returnedTextEstimatedTokens)" : other.referenceReturnedTextTokens.map(String.init) ?? tr("Unknown")
                    Text(tr("Unattributed measured text: %1$@ bytes / %2$@ tokens · %3$@ non-text blocks not tokenized", String(other.returnedTextBytes), tokens, String(other.nonTextBlocks)))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(tr("Includes execution wrapper text and may repeat separately logged MCP results. Kept outside MCP/Skill totals; no nested attribution or image/audio token estimate."))
                        .font(.caption).foregroundStyle(.secondary)
                } else if report.coverage.otherToolCalls > 0 {
                    Text(tr("Unattributed returned content was not measured in this report; analyze again."))
                        .font(.caption).foregroundStyle(.secondary)
                }
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
                        Text(tr("%1$@ calls · %2$@ results · %3$@ explicit result errors · %4$@ unknown error status · %5$@ missing results",
                                String(row.calls), String(row.completed), String(row.reportedErrors), String(row.unknownErrorStatus), String(row.missingResults)))
                            .font(.caption)
                        if let failures = row.invocationFailures {
                            if failures > 0 {
                                Text(tr("Host-reported invocation failures without MCP results: %1$@; excluded from result error proportions, included in timing.", String(failures)))
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        } else {
                            Text(tr("Host invocation failure counts were not measured in this report; analyze again."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
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
                        if kind == "skill" { instructionUsage(row.skillInstructions, encoding: row.referenceEncoding) }
                        if let encoding = row.referenceEncoding {
                            Text(tr("%1$@ reference text tokens: %2$@ · %3$@ results unavailable", encoding, row.referenceReturnedTextTokens.map(String.init) ?? tr("Unknown"), String(row.unavailableReferenceResults ?? 0))).font(.caption.monospaced())
                        }
                        if kind == "skill", sort == .instructions {
                            if let percentage = report.observedInstructionPercentage(of: row) {
                                Text(tr("Share of observed linked instruction text tokens: %1$@", String(format: "%.1f%%", percentage)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else if let percentage = textSummary.percentage(of: row) {
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
        .onChange(of: kind) { _ in visibleRowLimit = 8; sort = kind == "skill" ? .instructions : .text }
        .onChange(of: model.report?.generated) { _ in visibleRowLimit = 8 }
    }

    @ViewBuilder private func instructionUsage(_ loaded: SkillInstructionUsage?, encoding: String?) -> some View {
        if let loaded, loaded.events > 0 {
            let tokens = encoding == nil ? "≈\(loaded.estimatedTokens)" : loaded.referenceTokens.map(String.init) ?? tr("Unknown")
            Text(tr("Linked instruction loads: %1$@ · measured text %2$@ bytes / %3$@ tokens · %4$@ non-text blocks · %5$@ incomplete",
                    String(loaded.events), String(loaded.textBytes), tokens, String(loaded.nonTextBlocks), String(loaded.incompleteEvents)))
                .font(.caption).foregroundStyle(loaded.incompleteEvents > 0 ? .orange : .secondary)
        } else {
            Text(tr("No measured linked instruction loads in this report; total loading is unknown."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @MainActor private func chooseLog(host: String) {
        let panel = NSOpenPanel()
        panel.title = tr("Choose a %1$@ session log (JSONL)", host == "claude" ? "Claude" : "Codex")
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = false; panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(host == "claude" ? ".claude/projects" : ".codex/sessions")
        panel.begin { response in
            if response == .OK, let url = panel.url { model.analyze(encoding: encoding, logFile: url, host: host) }
        }
    }
}
