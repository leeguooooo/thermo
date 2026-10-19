import AgentDoctor
import AppKit
import SwiftUI
import ThermoL10n
import UniformTypeIdentifiers

@MainActor final class TaskComparisonModel: ObservableObject {
    @Published private(set) var loading = false
    @Published private(set) var report: TaskComparison.Report?
    @Published private(set) var error: String?
    private var generation = UUID()

    func load(_ url: URL) {
        guard !loading else { return }
        let generation = UUID()
        self.generation = generation
        loading = true; report = nil; error = nil
        Task.detached(priority: .utility) {
            let result = Result { try TaskComparison.read(url) }
            await MainActor.run {
                guard self.generation == generation else { return }
                switch result {
                case .success(let report): self.report = report
                case .failure(let error): self.error = (error as? TaskComparison.InvalidRecords)?.description ?? "Cannot read local evaluation file"
                }
                self.loading = false
            }
        }
    }
    func clear() {
        generation = UUID(); loading = false; report = nil; error = nil
    }
}

struct TaskComparisonPanel: View {
    @ObservedObject var model: TaskComparisonModel
    let kind: String
    @State private var showing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(tr("Task evaluation"), systemImage: "arrow.left.arrow.right").font(.headline)
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                Button(tr("Choose evaluation file…")) { chooseFile() }.disabled(model.loading)
            }
            Text(tr("Compare local task records from two versions or with and without a Skill. No tasks are run or uploaded."))
                .font(.caption).foregroundStyle(.secondary)
            if let error = model.error { Text(tr(error)).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            if let report = model.report {
                Text(report.evidenceKind == "synthetic" ? tr("Synthetic data · does not prove real task performance") : tr("Measured records · supplied outcomes have not been independently verified"))
                    .font(.callout).foregroundStyle(report.evidenceKind == "synthetic" ? .orange : .secondary)
                ComparisonCheckNotice(report: report)
                if report.kind == kind {
                    Text(tr("%1$@ paired runs across %2$@ tasks · %3$@ excluded pairs", String(report.matchedPairs), String(report.matchedTasks), String(report.excluded.count)))
                        .font(.caption.monospaced())
                    Button(tr("View comparison")) { showing = true }
                } else {
                    Text(tr("This report belongs to the other category. Open MCP Servers or Skills to view it, or choose another file."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.report != nil || model.error != nil || model.loading {
                Button(tr("Clear imported evaluation")) { model.clear() }.font(.caption)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18).glass()
        .sheet(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 12) {
                Text(tr("Task evaluation comparison")).font(.title2.bold())
                if let report = model.report, report.kind == kind { TaskComparisonResultView(report: report) }
                HStack { Spacer(); Button(tr("Close")) { showing = false }.keyboardShortcut(.cancelAction) }
            }.padding(24).frame(minWidth: 560, idealWidth: 680, minHeight: 400, idealHeight: 600)
        }
    }

    @MainActor private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = tr("Choose a task evaluation JSON file")
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.begin { response in
            if response == .OK, let url = panel.url { model.load(url) }
        }
    }
}

struct TaskComparisonResultView: View {
    let report: TaskComparison.Report
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(report.evidenceKind == "synthetic" ? tr("Synthetic data · does not prove real task performance") : tr("Measured records · supplied outcomes have not been independently verified"))
                    .font(.headline).foregroundStyle(report.evidenceKind == "synthetic" ? .orange : .secondary)
                ComparisonCheckNotice(report: report)
                Text(tr("Reported outcomes · all imported runs")).font(.headline)
                outcomes(tr("Baseline"), report.reportedBaseline)
                outcomes(tr("Candidate"), report.reportedCandidate)
                Divider()
                Text(tr("Comparable pairs only")).font(.headline)
                Text(tr("Model: %1$@", report.model)).font(.callout.monospaced())
                Text(tr("%1$@ paired runs across %2$@ tasks · %3$@ excluded pairs", String(report.matchedPairs), String(report.matchedTasks), String(report.excluded.count)))
                if report.matchedPairs > 0 {
                    Text(tr("Pairs with reported outcomes: %1$@ · unknown outcomes: %2$@", String(report.verifiedOutcomePairs), String(report.matchedPairs - report.verifiedOutcomePairs)))
                    outcomes(tr("Baseline"), report.baseline)
                    outcomes(tr("Candidate"), report.candidate)
                    Text(tr("Both passed %1$@ · candidate only %2$@ · baseline only %3$@ · neither passed %4$@", String(report.bothPassed), String(report.candidateOnlyPassed), String(report.baselineOnlyPassed), String(report.neitherPassed)))
                } else {
                    Text(tr("No comparable pairs. Reported task outcomes above are retained."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let difference = report.passRateDifferencePercentagePoints {
                    Text(tr("Pass-rate difference: %1$@ percentage points", String(format: "%+.2f", difference)))
                } else { Text(tr("Pass-rate difference: unknown")) }
                Divider()
                Text(tr("Differences are candidate minus baseline. Positive values mean more time or tokens; unsuccessful runs are included when measured."))
                    .font(.caption).foregroundStyle(.secondary)
                metric(tr("Elapsed seconds"), report.seconds)
                metric(tr("Native input tokens"), report.inputTokens)
                metric(tr("Native output tokens"), report.outputTokens)
                Text(tr("Token accounting mismatches: %1$@ pairs", String(report.tokenSemanticsMismatchPairs))).font(.caption)
                if !report.excluded.isEmpty {
                    DisclosureGroup(tr("Excluded pairs")) {
                        ForEach(Array(report.excluded.enumerated()), id: \.offset) { _, entry in
                            Text(tr("%1$@ · repetition %2$@ · %3$@", entry.taskID, String(entry.repetition), exclusionReason(entry.reason)))
                                .font(.caption.monospaced())
                        }
                    }
                }
                DisclosureGroup(tr("Declared versions and conditions")) {
                    Text(tr("Baseline: %1$@", report.baselineRevision))
                    Text(tr("Candidate: %1$@", report.candidateRevision))
                    Text(tr("Environment: %1$@", report.environment))
                    Text(tr("Settings: %1$@", report.settings))
                }.font(.caption.monospaced())
                Text(tr("Imported records are not automatically linked to installed tools. Thermo checks record consistency, not outcome authenticity. Repeated tasks have more weight; this descriptive comparison does not establish significance or overall quality."))
                    .font(.caption).foregroundStyle(.secondary)
            }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8)
        }
    }
    private func exclusionReason(_ reason: String) -> String {
        switch reason {
        case "missing_variant": return tr("Missing baseline or candidate")
        case "comparison_check_failed": return tr("Post-run comparison check failed")
        case "comparison_check_unverified": return tr("Post-run comparison check missing or unverified")
        default: return tr("Task or verifier conditions differ")
        }
    }
    private func outcomes(_ title: String, _ value: TaskComparison.Outcomes) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(tr("Passed %1$@ · failed %2$@ · timeout %3$@ · error %4$@ · unverified %5$@", String(value.passed), String(value.failed), String(value.timeout), String(value.error), String(value.unverified)))
                .font(.caption.monospaced())
        }
    }
    private func metric(_ title: String, _ value: TaskComparison.Delta) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            if let median = value.medianCandidateMinusBaseline, let minimum = value.minimumCandidateMinusBaseline, let maximum = value.maximumCandidateMinusBaseline {
                Text(tr("Median difference %1$@ · range %2$@ to %3$@ · %4$@ paired samples", String(format: "%+.3f", median), String(format: "%+.3f", minimum), String(format: "%+.3f", maximum), String(value.samples)))
                    .font(.caption.monospaced())
            } else { Text(tr("Unknown · no paired measurements")).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

private struct ComparisonCheckNotice: View {
    let report: TaskComparison.Report
    var body: some View {
        if report.comparisonCheckFailedRuns > 0 || report.comparisonCheckUnverifiedRuns > 0 {
            Text(tr("Post-run comparison checks: %1$@ failed · %2$@ unverified. Affected pairs are excluded; reported task outcomes remain available.", String(report.comparisonCheckFailedRuns), String(report.comparisonCheckUnverifiedRuns)))
                .font(.callout).foregroundStyle(.orange)
        }
    }
}
