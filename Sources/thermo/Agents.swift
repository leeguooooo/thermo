import AgentDoctor
import ThermoL10n
import Foundation

/// `thermo agents`: what is wrong with the AI agents on this Mac.
private var mcpBatchInterrupted: sig_atomic_t = 0

struct AgentsCommand {
    let app: App
    var style: Style { app.style }

    func environment() throws -> DoctorEnvironment {
        var project: URL?
        if let path = app.args.options["root"] {
            let value = URL(fileURLWithPath:(path as NSString).expandingTildeInPath).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath:value.path,isDirectory:&isDirectory), isDirectory.boolValue else { throw CLIError("--root must identify one existing project directory.") }
            project = value
        }
        return DoctorEnvironment(project:project,tokenEncoding:try encoding())
    }

    func run(_ rest: [String]) throws {
        let sub = rest.first ?? ""
        let name = rest.count > 1 ? rest[1] : nil
        switch sub {
        case "claude-local":
            guard rest.count == 1 else { throw CLIError("usage: thermo agents claude-local [--json]") }
            let report = ClaudeLocalDiagnostics().scan()
            if app.args.has("json") { print(report.json) }
            else {
                print(tr("Claude local diagnostics"))
                print(report.generatedAt)
                for check in report.checks {
                    print("[\(tr(check.status.displayName))] \(tr(check.title)): \(tr(check.value)) · \(check.source)")
                }
                print(tr("Some results remain unknown. This report cannot predict account suspension or establish what Claude sends."))
            }
            return
        case "": break
        case "context": return try context()
        case "inspect-all": return try inspectAll()
        case "compare":
            guard rest.count == 2 else { throw CLIError("usage: thermo agents compare FILE [--json]") }
            return try compareTasks(try required(name, sub))
        case "usage":
            guard rest.count == 1 else { throw CLIError("usage: thermo agents usage [--since ISO_DATE] [--agent claude|codex] [--log-file FILE] [--tail] [--sort text|structured|time|errors|instructions] [--limit FILES] [--json]") }
            return try usage()
        case "inspect":
            guard rest.count == 2 else { throw CLIError("usage: thermo agents inspect NAME [--agent AGENT] [--timeout SECONDS] [--json]") }
            return try inspectMCP(try required(name, sub))
        case "list", "ls": return try list(name)
        case "show": return try show(try required(name, sub))
        case "fix":
            if let name { return try act(on: name, kind: .fix) }
            return try fixAll()
        case "uninstall", "remove", "rm": return try act(on: try required(name, sub), kind: .uninstall)
        case "disable": return try act(on: try required(name, sub), kind: .disable)
        case "updates":
            guard rest.count == 1 else { throw CLIError("usage: thermo agents updates [--check] [--json]") }
            return try updates()
        case "update":
            if let name { return try act(on: name, kind: .update) }
            return try updateAll()
        case "run": return try act(on: try required(name, sub), kind: nil)
        default: throw CLIError(Self.usage)
        }
        let report = AgentDoctor.run(try environment())
        if app.args.has("json") {
            print(Export.diagnosticJSON(report))
            if report.count(.error) > 0 { exit(1) }
            return
        }
        if app.args.has("csv") {
            print(Export.diagnosticCSV(items: report.items, findings: report.findings, generated: report.generated))
            if report.count(.error) > 0 { exit(1) }
            return
        }
        let all = app.args.has("all")
        let inv = report.inventory
        var lines = [
            style.bold("thermo agents") + style.dim(" · " + (inv.agents.isEmpty ? "no AI agents found" : inv.agents.joined(separator: ", "))),
            style.dim("  \(inv.hooks) hooks · \(inv.mcpServers) MCP servers · \(inv.plugins) plugins · \(inv.skills) skills · "
                      + "\(inv.launchAgents) launch agents · \(report.sessions) Claude sessions"),
            "",
        ]

        let shown = report.findings.filter { all || $0.severity != .info }
        for area in Area.allCases {
            let items = shown.filter { $0.area == area }
            guard !items.isEmpty else { continue }
            lines.append(style.bold(title(area)))
            for f in items {
                let mark = f.severity == .error ? style.red(f.severity.symbol) : f.severity == .warning ? style.yellow(f.severity.symbol) : style.dim(f.severity.symbol)
                let agent = f.agent == "system" ? "" : style.dim(" [\(f.agent)]")
                lines.append("  \(mark) " + style.bold(f.subject) + agent)
                lines.append("    " + f.message)
                if let fix = f.fix { lines.append("    " + style.cyan("→ " + fix)) }
                if all, let src = f.source { lines.append("    " + style.dim(src)) }
            }
            lines.append("")
        }

        let top = report.processes.prefix(all ? 15 : 8)
        if !top.isEmpty {
            lines.append(style.bold("Agent processes") + style.dim("  (by resident memory, RSS)"))
            for g in top {
                let detached = g.detached > 0 ? style.yellow("  \(g.detached) detached") : ""
                lines.append("  " + pad(String(g.count), 4, right: true) + "×  "
                             + pad(String(format: "%.0f MB", g.rssMB), 9, right: true)
                             + pad(String(format: "%.0f%%", g.cpu), 6, right: true) + "  " + g.name + detached)
            }
            lines.append("")
        }

        let hidden = report.count(.info)
        let summary = !report.hasResults ? style.dim(report.headline) : report.count(.error) > 0 ? style.red(report.headline) : report.count(.warning) > 0 ? style.yellow(report.headline) : style.green(report.headline)
        lines.append(summary + (all || hidden == 0 ? "" : style.dim("  (+\(hidden) notes; --all to show)")))
        out(lines)
        if report.count(.error) > 0 { exit(1) }
    }

    /// Everything that was checked, one line each, marked ✓ healthy / · note / ! warning / ✗ error / - off.
    func list(_ filter: String?) throws {
        let areas: [Area]
        if let filter {
            guard let a = Area(rawValue: filter) else {
                throw CLIError("unknown area '\(filter)'; areas: " + Area.allCases.map(\.rawValue).joined(separator: ", "))
            }
            areas = [a]
        } else {
            areas = Area.allCases
        }
        let report = AgentDoctor.run(try environment())
        let items = report.items.filter { areas.contains($0.area) }
        if app.args.has("json") { print(Export.diagnosticJSON(items)); return }
        if app.args.has("csv") {
            print(Export.diagnosticCSV(items: items, findings: report.findings.filter { areas.contains($0.area) }, generated: report.generated))
            return
        }
        var lines: [String] = []
        for area in areas {
            let rows = items.filter { $0.area == area }
            guard !rows.isEmpty else { continue }
            let bad = rows.filter { $0.severity == .error || $0.severity == .warning }.count
            lines.append(style.bold(title(area)) + style.dim("  \(rows.count)") + (bad > 0 ? style.yellow("  \(bad) with problems") : style.green("  all OK")))
            for i in rows {
                let mark: String
                switch (i.enabled, i.severity) {
                case (false, _): mark = style.dim("-")
                case (_, .error?): mark = style.red("✗")
                case (_, .warning?): mark = style.yellow("!")
                case (_, .info?): mark = style.dim("·")
                case (_, nil): mark = style.green("✓")
                }
                let agent = i.agent == "system" ? "" : style.dim(" [\(i.agent)]")
                lines.append("  \(mark) " + i.name + agent + "  " + style.dim(String(i.detail.prefix(90))))
                if i.severity == .error || i.severity == .warning {
                    for f in report.findings(for: i) where f.severity != .info { lines.append("      " + f.message) }
                }
            }
            lines.append("")
        }
        out(lines)
    }

    static let usage = """
    usage: thermo agents [--all] [--json]                 what is wrong with the AI agents on this Mac
           thermo agents claude-local [--json]             read-only local Claude identity, telemetry and routing checks
           thermo agents context [--agent AGENT] [--root PROJECT] [--json] static footprint ranking and deduplicated inventory
           thermo agents usage [--since ISO_DATE] [--agent claude|codex] [--sort text|structured|time|errors|instructions] [--limit FILES] [--json] local log metrics
           thermo agents compare FILE [--json]            compare declared local task evaluations; never executes tasks
           thermo agents inspect NAME [--protocol handshake|2026-07-28] [--json] connect to one MCP; discover, list and rank definitions
           thermo agents list [AREA] [--json]             everything checked, marked OK or not
           thermo agents show NAME [--json]               one item: problems, suggestions, numbered actions
           thermo agents fix [--dry-run] [--yes]          every safe automatic fix for problem items
           thermo agents fix|uninstall|disable NAME       that action on one item
           thermo agents run NAME --action N              action N from `show`
           thermo agents updates [--check] [--json]       plugins and skills with a newer version; --check asks GitHub about skills
           thermo agents update [NAME] [--dry-run] [--yes] update one item, or every one with an update
      NAME is the item's name or id; narrow with --area AREA and --agent AGENT, or --all for every match.
      --encoding heuristic|cl100k_base|o200k_base selects ordinary-text reference counts for context/inspect/usage.
      Actions print their exact steps first and ask; --yes skips the question, --dry-run only prints.
    """

    func encoding() throws -> TextEncoding {
        guard let name = app.args.options["encoding"] else { return .heuristic }
        guard let value = TextEncoding(rawValue: name) else { throw CLIError("--encoding must be heuristic, cl100k_base or o200k_base; model names are not inferred") }
        return value
    }

    func compareTasks(_ path: String) throws {
        guard app.args.flags.isSubset(of: ["json", "no-color"]), app.args.options.isEmpty else {
            throw CLIError("agents compare accepts only FILE, --json and --no-color")
        }
        let report = try TaskComparison.read(URL(fileURLWithPath: path))
        if app.args.has("json") { print(Export.diagnosticJSON(report)); return }
        func metric(_ label: String, _ value: TaskComparison.Delta) -> String {
            guard let median = value.medianCandidateMinusBaseline else { return "\(label): unknown (0 paired samples)" }
            return "\(label): median Δ \(String(format: "%+.3f", median)) · range \(String(format: "%+.3f", value.minimumCandidateMinusBaseline!))…\(String(format: "%+.3f", value.maximumCandidateMinusBaseline!)) · \(value.samples) paired samples"
        }
        func outcomes(_ label: String, _ value: TaskComparison.Outcomes) -> String {
            "\(label): passed \(value.passed) · failed \(value.failed) · timeout \(value.timeout) · error \(value.error) · unverified \(value.unverified)"
        }
        let exclusions = Dictionary(grouping: report.excluded, by: \.reason).map { "\($0.key): \($0.value.count)" }.sorted().joined(separator: ", ")
        out([style.bold("Declared task evaluation comparison"),
             "Evidence: \(report.evidenceKind) · \(report.kind) · model \(report.model)",
             "\(report.totalRuns) records · \(report.matchedPairs) matched pairs across \(report.matchedTasks) tasks · \(report.excluded.count) excluded pairs",
             "Exclusions: " + (exclusions.isEmpty ? "none" : exclusions),
             "Post-run comparison checks: \(report.comparisonCheckFailedRuns) failed · \(report.comparisonCheckUnverifiedRuns) unverified",
             outcomes("Reported baseline (all runs)", report.reportedBaseline), outcomes("Reported candidate (all runs)", report.reportedCandidate),
             outcomes("Comparable baseline", report.baseline), outcomes("Comparable candidate", report.candidate),
             "Verified outcomes: \(report.verifiedOutcomePairs) pairs · both passed \(report.bothPassed) · candidate only \(report.candidateOnlyPassed) · baseline only \(report.baselineOnlyPassed) · neither \(report.neitherPassed)",
             "Pass-rate difference: " + (report.passRateDifferencePercentagePoints.map { String(format: "%+.2f percentage points", $0) } ?? "unknown"),
             metric("Elapsed seconds", report.seconds), metric("Native input tokens", report.inputTokens), metric("Native output tokens", report.outputTokens),
             "Token accounting mismatches: \(report.tokenSemanticsMismatchPairs) pairs", report.note])
    }

    func usage() throws {
        guard !app.args.has("csv"), app.args.options["root"] == nil else { throw CLIError("agents usage supports --json; project filtering and CSV are not supported") }
        let host = app.args.options["agent"]
        guard host == nil || ["claude", "codex"].contains(host!) else { throw CLIError("--agent must be claude or codex") }
        let logFile = app.args.options["log-file"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        guard logFile == nil || host != nil else { throw CLIError("--log-file requires --agent claude or codex") }
        let count = try app.args.int("limit") ?? 100
        guard count <= 1000 else { throw CLIError("--limit must be between 1 and 1000 files") }
        var since: Date?
        if let text = app.args.options["since"] {
            let iso = ISO8601DateFormatter()
            since = iso.date(from: text)
            if since == nil {
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                since = iso.date(from: text)
            }
            if since == nil {
                let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.timeZone = TimeZone(secondsFromGMT: 0); date.dateFormat = "yyyy-MM-dd"; date.isLenient = false
                if let parsed = date.date(from: text), date.string(from: parsed) == text { since = parsed }
            }
            guard let since, since <= Date() else { throw CLIError("--since must be a past ISO date or YYYY-MM-DD (UTC)") }
        }
        guard let ordering = ToolUsageOrdering(rawValue: app.args.options["sort"] ?? "text") else { throw CLIError("--sort must be text, structured, time, errors or instructions") }
        var report = AgentDoctor.usage(since: since, host: host, fileLimit: count, logFile: logFile,
                                      logWindow: app.args.has("tail") ? .tail : .head, env: DoctorEnvironment(tokenEncoding: try encoding()))
        report.tools = ordering.sorted(report.tools)
        report.toolOrdering = ordering
        report.note += " " + ordering.explanation
        if app.args.has("json") { print(Export.diagnosticJSON(report)); return }
        let iso = ISO8601DateFormatter()
        let coverage = report.coverage
        var lines = [style.bold("Observed local tool usage"), iso.string(from: report.since) + " → " + iso.string(from: report.until),
                     report.logReadScopeExplanation,
                     "Log reading: " + (report.complete ? "complete within selected scope" : "partial"),
                     "\(coverage.filesRead)/\(coverage.filesDiscovered) eligible files · \(coverage.bytesRead) bytes · \(coverage.clippedFiles) clipped · \(coverage.malformedLines) malformed records", ""]
        if let encoding = report.referenceEncoding { lines.append("Ordinary-text reference encoding: " + encoding + "; not a model invoice or prompt framing count") }
        lines.append("Tool ordering: " + ordering.rawValue + "; JSON uses the same order.")
        lines.append(ordering.explanation)
        if ordering == .structured { lines.append("Only MCP rows with known structured JSON counts are ranked; other categories remain present after known values.") }
        let textSummaries = Dictionary(uniqueKeysWithValues: Set(report.tools.map(\.kind)).sorted().map { kind in
            (kind, report.returnedTextSummary(kind: kind))
        })
        for kind in textSummaries.keys.sorted() {
            let summary = textSummaries[kind]!
            let tokens = summary.returnedTextTokens.map { (report.referenceEncoding == nil ? "≈" : "") + String($0) } ?? "unknown"
            lines.append("Observed \(kind) returned text total (all rows): \(summary.returnedTextBytes.map(String.init) ?? "unknown") bytes / \(tokens) tokens")
        }
        if !report.tools.isEmpty { lines.append("Totals cover observed returned text only; missing logs/results and non-text content are excluded, not request usage.") }
        let structuredSummary = report.observedMCPStructuredSummary
        if report.tools.contains(where: { $0.kind == "mcp" }) {
            lines += structuredSummary?.displayLines ?? [MCPStructuredContentSummary.unavailableExplanation]
        }
        for kind in Set(report.tools.map(\.kind)).sorted() {
            lines.append("Observed " + kind + " timing:")
            lines += report.timingSummary(kind: kind)?.displayLines ?? [ToolUsageTimingSummary.unavailableExplanation]
        }
        lines.append(ToolUsageTimingSummary.explanation)
        func instructionLine(_ loaded: SkillInstructionUsage?) -> String {
            guard let loaded, loaded.events > 0 else { return "No measured linked instruction loads in this report; total loading is unknown." }
            let tokens = report.referenceEncoding == nil ? "≈\(loaded.estimatedTokens)" : loaded.referenceTokens.map(String.init) ?? "unknown"
            return "Linked instruction loads: \(loaded.events) · measured text \(loaded.textBytes) bytes / \(tokens) tokens · \(loaded.nonTextBlocks) non-text blocks · \(loaded.incompleteEvents) incomplete"
        }
        if report.tools.contains(where: { $0.kind == "skill" }) {
            lines.append(instructionLine(report.observedSkillInstructions))
            lines.append("Only explicitly source-linked Claude instruction messages are measured. Kept separate from tool replies and request counters; missing loads, referenced files and billing remain unknown.")
        }
        func representationNotes(_ row: ToolUsageRow) -> [String] {
            var notes: [String] = []
            if let count = row.serializedMediaTextResults, count > 0 {
                notes.append("Serialized media inside text: \(count) results; logged-text counts are not media token cost or proof of model delivery.")
                if let line = row.serializedMediaTextCompositionLine { notes.append(line) }
            }
            if let count = row.truncationMarkerResults, count > 0 {
                notes.append("Explicit truncation markers: \(count) result texts; full returned size unknown.")
            }
            return notes
        }
        for row in report.tools.prefix(app.args.has("all") ? report.tools.count : 20) {
            lines.append(style.bold((row.server.map { $0 + " / " } ?? "") + row.name) + " [" + row.host + ", " + row.kind + "]")
            lines.append("  \(row.calls) calls · \(row.completed) results · \(row.reportedErrors) explicit result errors · \(row.unknownErrorStatus) unknown error status · \(row.missingResults) missing results")
            if ordering == .instructions, row.kind == "skill" {
                let count = ordering.count(for: row).map { (row.referenceEncoding == nil ? "≈" : "") + String($0) } ?? "unknown"
                lines.append("  Observed instruction text tokens: \(count)")
            }
            if ordering == .errors { lines.append("  Observed errors / failures: \(ordering.count(for: row).map(String.init) ?? "unknown")") }
            if ordering == .time { lines.append("  Valid timing pairs: \(row.timingSamples) / \(row.calls) calls") }
            if let codes = row.mcpErrorCodeSummary { lines.append("  " + codes) }
            if row.kind == "skill" { lines.append("  " + instructionLine(row.skillInstructions)) }
            if let failures = row.invocationFailures {
                if failures > 0 { lines.append("  Host-reported invocation failures without MCP results: \(failures); excluded from result error proportions, included in timing.") }
            } else { lines.append("  Host invocation failure counts were not measured in this report; analyze again.") }
            if let rate = row.explicitErrorRate, let denominator = row.knownStatusResults {
                lines.append("  explicit errors among known-status results: \(row.reportedErrors) / \(denominator) (\(String(format: "%.1f%%", rate * 100)))")
            } else { lines.append("  explicit error rate unknown; no usable known-status denominator") }
            let median = row.medianSeconds.map { String(format: "%.3fs", $0) } ?? "unknown"
            let p95 = row.p95Seconds.map { String(format: "%.3fs", $0) } ?? "unknown (requires 20 samples)"
            if let encoding = row.referenceEncoding { lines.append("  " + encoding + ": " + (row.referenceReturnedTextTokens.map(String.init) ?? "unknown") + " reference tokens; unavailable results: \(row.unavailableReferenceResults ?? 0)") }
            lines.append("  result text: \(row.returnedTextBytes) bytes / ≈\(row.returnedTextEstimatedTokens) tokens · median \(median) · P95 \(p95) · \(row.nonTextBlocks) non-text blocks not tokenized")
            lines += row.mcpStructuredContentLines(includeRepresentationNotes: structuredSummary == nil).map { "  " + $0 }
            lines += representationNotes(row).map { "  " + $0 }
            if ordering == .text, let percentage = textSummaries[row.kind]?.percentage(of: row) {
                lines.append("  share of observed \(row.kind) returned-text tokens: \(String(format: "%.1f%%", percentage))")
            }
        }
        if report.tools.isEmpty { lines.append("No directly attributable MCP or explicit Skill calls were observed; this does not prove they were unused.") }
        else { lines.append(ToolUsageReport.errorStatusExplanation) }
        lines += ["", "Request counters (not individual tool consumption):"]
        if report.sessionTokens.isEmpty { lines.append("  No supported request token records; usage is unknown.") }
        for tokens in report.sessionTokens {
            lines.append("  \(tokens.host): \(tokens.requests) requests · input \(tokens.inputTokens) · output \(tokens.outputTokens) · cached input \(tokens.cachedInputTokens.map(String.init) ?? "unknown") · cache creation \(tokens.cacheWriteInputTokens.map(String.init) ?? "unknown")")
        }
        if let snapshots = report.cumulativeTokenSnapshots, !snapshots.isEmpty {
            lines += ["", "Native cumulative snapshots (not window usage):", ToolUsageReport.cumulativeTokenExplanation]
            for snapshot in snapshots { lines += snapshot.displayLines.map { "  " + $0 } }
        }
        lines.append("Other tool calls: \(coverage.otherToolCalls); unmatched results: \(coverage.unmatchedResults); unsupported usage events: \(coverage.unsupportedUsageRecords)")
        if let unmatched = coverage.unmatchedInstructionEvents, unmatched > 0 { lines.append("\(unmatched) instruction metadata records could not be linked or identified.") }
        if let other = coverage.unattributedResults {
            let tokens = report.referenceEncoding == nil ? "≈\(other.returnedTextEstimatedTokens)" : other.referenceReturnedTextTokens.map(String.init) ?? "unknown"
            lines.append("Unattributed tool results: \(other.completed) returned · \(other.missingResults) missing · \(other.unmeasuredResults) unmeasured")
            lines.append("Unattributed measured text: \(other.returnedTextBytes) bytes / \(tokens) tokens · \(other.nonTextBlocks) non-text blocks not tokenized")
            lines.append("Includes execution wrapper text and may repeat separately logged MCP results. Kept outside MCP/Skill totals; no nested attribution or image/audio token estimate.")
            lines.append("Observed outer timing:")
            lines += report.timingSummary(kind: "outer")?.displayLines ?? [ToolUsageTimingSummary.unavailableExplanation]
            if let rows = other.byTool {
                if !rows.isEmpty {
                    let count = app.args.has("all") ? rows.count : min(20, rows.count)
                    let outerSummary = report.outerReturnedTextSummary
                    lines.append("Outer tools ranked by observed returned text: showing \(count)/\(rows.count)")
                    lines.append("Same observations as the outer aggregate, not additional usage. Commands and nested CLI/MCP ownership are not inferred.")
                    if other.unmeasuredResults > 0 { lines.append("Some returned content was not measured; this ranks measured text only.") }
                    for row in rows.prefix(count) {
                        let tokens = report.referenceEncoding == nil ? "≈\(row.returnedTextEstimatedTokens)" : row.referenceReturnedTextTokens.map(String.init) ?? "unknown"
                        lines.append("  \(row.name) [\(row.host)]: \(row.calls) calls · \(row.completed) results · \(row.missingResults) missing · \(row.returnedTextBytes) text bytes / \(tokens) tokens")
                        lines += representationNotes(row).map { "    " + $0 }
                        lines.append("    \(row.reportedErrors) explicit result errors · \(row.unknownErrorStatus) unknown error status · \(row.unmeasuredResults.map(String.init) ?? "unknown") results with unmeasured content · \(row.nonTextBlocks) non-text blocks")
                        let median = row.medianSeconds.map { String(format: "%.3fs", $0) } ?? "unknown"
                        let p95 = row.p95Seconds.map { String(format: "%.3fs", $0) } ?? "unknown (requires 20 samples)"
                        lines.append("    median \(median) · P95 \(p95) · observed sum \(row.totalObservedSeconds.map { String(format: "%.3fs", $0) } ?? "unknown")")
                        if let rate = row.explicitErrorRate, let denominator = row.knownStatusResults {
                            lines.append("    explicit errors among known-status results: \(row.reportedErrors) / \(denominator) (\(String(format: "%.1f%%", rate * 100)))")
                        } else { lines.append("    explicit error rate unknown; no usable known-status denominator") }
                        if let share = outerSummary?.percentage(of: row) {
                            lines.append("    share of observed outer returned-text tokens: \(String(format: "%.1f%%", share))")
                        }
                    }
                    lines.append(ToolUsageReport.errorStatusExplanation)
                }
            } else { lines.append("Per-tool outer rankings were not measured in this report; analyze again.") }
        } else { lines.append("Unattributed returned content was not measured in this report; analyze again.") }
        lines.append(report.note)
        out(lines)
    }

    struct BatchInspectionReport: Encodable {
        let complete: Bool
        let reason: String
        let total: Int
        let notStarted: Int
        let results: [MCPInspection]
    }
    func inspectAll() throws {
        guard app.args.positionals.count == 2 else { throw CLIError("inspect-all takes no names; use --agent to select a host") }
        let timeout = try app.args.double("timeout") ?? 10, budget = try app.args.double("budget") ?? 120
        guard timeout <= 120, budget <= 120 else { throw CLIError("--timeout and --budget must be at most 120 seconds") }
        if let host = app.args.options["agent"], !["claude","codex","cursor","gemini","windsurf"].contains(host) { throw CLIError("Unknown --agent host.") }
        let selectedEncoding = try encoding()
        let protocolMode = MCPInspectionProtocol(rawValue: app.args.options["protocol"] ?? "handshake")!
        let selectedProject = try environment().project
        let inventory = AgentDoctor.run(DoctorEnvironment(project:selectedProject,tokenEncoding: selectedEncoding))
        var seen = Set<String>()
        let queue = inventory.items.filter { $0.area == .mcp && $0.enabled && (app.args.options["agent"] == nil || $0.agent == app.args.options["agent"]) && seen.insert($0.id).inserted }
            .sorted { ($0.agent,$0.name,$0.id) < ($1.agent,$1.name,$1.id) }
        if app.args.has("dry-run") {
            struct Plan: Encodable { let dryRun = true; let ids: [String]; let timeout: Double; let budget: Double; let inspectionProtocol: MCPInspectionProtocol }
            print(Export.json(Plan(ids:queue.map(\.id),timeout:timeout,budget:budget,inspectionProtocol:protocolMode))); return
        }
        mcpBatchInterrupted = 0
        let old = signal(SIGINT) { _ in mcpBatchInterrupted = 1 }
        defer { signal(SIGINT,old) }
        let deadline = ProcessInfo.processInfo.systemUptime + budget
        var results: [MCPInspection] = [], reason = "finished"
        for item in queue {
            if mcpBatchInterrupted != 0 { reason = "cancelled"; break }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { reason = "budgetExpired"; break }
            let report = AgentDoctor.inspectMCP(item.id, timeout:min(timeout,remaining),
                protocolMode:protocolMode,
                env:DoctorEnvironment(project:selectedProject,tokenEncoding:selectedEncoding,cancelled:{ mcpBatchInterrupted != 0 || ProcessInfo.processInfo.systemUptime >= deadline }))
            results.append(report)
            if !app.args.has("json") { print(item.agent + " / " + item.name + " · " + report.state.rawValue) }
        }
        if mcpBatchInterrupted != 0 { reason = "cancelled" }
        let complete = results.count == queue.count && results.allSatisfy { $0.complete && $0.state == .ready && $0.definitions != nil && $0.instructions != nil }
        let report = BatchInspectionReport(complete:complete,reason:reason,total:queue.count,notStarted:queue.count-results.count,results:results)
        if app.args.has("json") { print(Export.diagnosticJSON(report)) }
        if !complete { throw CLIError("MCP batch inspection is incomplete; inspect individual results.",exitCode:3) }
    }

    func inspectMCP(_ name: String) throws {
        guard !app.args.has("csv"), !app.args.has("all"), !app.args.has("dry-run") else {
            throw CLIError("agents inspect supports one server, --agent, --timeout and --json")
        }
        let protocolMode = MCPInspectionProtocol(rawValue: app.args.options["protocol"] ?? "handshake")!
        let report = AgentDoctor.inspectMCP(name, agent: app.args.options["agent"], timeout: try app.args.double("timeout") ?? 10, protocolMode: protocolMode, env: try environment())
        if app.args.has("json") { print(Export.diagnosticJSON(report)) }
        else {
            var lines = [style.bold(report.name) + " [" + report.agent + "] · " + report.state.rawValue, report.message,
                         String(format: "Elapsed %.3fs", report.elapsedSeconds)]
            func seconds(_ value: Double?) -> String { value.map { String(format: "%.3fs", $0) } ?? "not measured" }
            if let discovery = report.discoverySeconds {
                lines.append(tr("Discovery %1$@ · list %2$@", seconds(discovery), seconds(report.listingSeconds)))
            } else if report.transport == "streamable-http" {
                lines.append("HTTP handshake \(seconds(report.handshakeSeconds)) · list \(seconds(report.listingSeconds))")
            } else { lines.append("Start \(seconds(report.startupSeconds)) · handshake \(seconds(report.handshakeSeconds)) · list \(seconds(report.listingSeconds))") }
            if let encoding = report.referenceEncoding { lines.append("Ordinary-text reference encoding: " + encoding + "; not a model invoice or prompt framing count") }
            if let analysis = report.analysisSeconds { lines.append(String(format: "Local analysis %.3fs", analysis)) }
            if let definitions = report.definitions {
                lines.append("\(report.tools.count) tools · definitions ≈\(definitions.tokenLabel) tokens · \(definitions.bytes) bytes")
            }
            if let instructions = report.instructions { lines.append("Server instructions ≈\(instructions.tokenLabel) tokens") }
            for tool in report.tools {
                lines.append("  " + tool.name + " ≈\(tool.definition.tokenLabel) tokens (description \(tool.description.tokenLabel), input schema \(tool.inputSchema.tokenLabel), output schema \(tool.outputSchema.tokenLabel))")
                if let icons = tool.icons, let metadata = tool.metadata {
                    lines.append("    icons JSON \(icons.bytes) bytes / ≈\(icons.tokenLabel) tokens; _meta JSON \(metadata.bytes) bytes / ≈\(metadata.tokenLabel) tokens")
                } else { lines.append("    Icon and _meta counts were not measured in this report.") }
                for issue in tool.issues { lines.append("    ! " + issue) }
            }
            if let cleanup = report.cleanupStatus { lines.append("HTTP session cleanup: " + cleanup) }
            if let details = report.cleanupDetails, details.reason != "notNeeded" { lines.append(details.summary) }
            lines.append(report.measurementNote)
            if !report.tools.isEmpty { lines.append(MCPToolFootprint.metadataNote) }
            out(lines)
        }
        if report.state != .ready { throw CLIError("MCP inspection did not produce a complete tool listing.") }
    }

    func context() throws {
        guard !app.args.has("csv") else { throw CLIError("agents context supports --json, not --csv") }
        let project = app.args.options["root"].map { URL(fileURLWithPath: $0).standardizedFileURL }
        if let project {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: project.path, isDirectory: &directory), directory.boolValue else {
                throw CLIError("--root must name an existing project directory")
            }
        }
        var report = AgentDoctor.context(DoctorEnvironment(project: project, tokenEncoding: try encoding()))
        if let agent = app.args.options["agent"] {
            let visible = agent == "codex" ? ["codex", "shared", "codex-cache"] : agent == "claude" ? ["claude", "plugin"] : [agent]
            report.skills = report.skills.filter { visible.contains($0.agent) }
            report.mcpServers = report.mcpServers.filter { $0.agent == agent }
            let ids = Set((report.skills + report.mcpServers).map(\.id))
            report.findings = report.findings.filter { $0.item.map(ids.contains) ?? visible.contains($0.agent) }
        }
        report.summaries = SkillContextSummary.summarize(report.skills)
        report.qualitySummaries = SkillQualitySummary.summarize(report.skills)
        if app.args.has("json") { print(Export.diagnosticJSON(report)); return }
        var lines = [style.bold("Skill footprint · static estimates"), report.coverageNote, report.measurementNote, ""]
        if let encoding = report.referenceEncoding { lines.append("Ordinary-text reference encoding: " + encoding + "; not a model invoice or prompt framing count") }
        for summary in report.summaries {
            if let encoding = summary.referenceEncoding {
                lines.append("\(summary.host) \(encoding): catalog \(summary.referenceCatalogTokens.map(String.init) ?? "unknown"), documents \(summary.referenceDocumentTokens.map(String.init) ?? "unknown"); unavailable files \(summary.unavailableReferenceFiles ?? 0)")
            }
            lines.append("\(summary.host) heuristic comparison: \(summary.uniqueFiles) unique directory/plugin files · catalog ≈\(summary.catalogEstimatedTokens.map(String.init) ?? "Unknown") tokens · documents ≈\(summary.documentEstimatedTokens) tokens · \(summary.documentBytes) bytes · \(summary.aliases) duplicate file entries excluded from document totals")
            if summary.inconsistentFiles > 0 || summary.unverifiedIdentityEntries > 0 { lines.append("  excluded: \(summary.inconsistentFiles) changing files, \(summary.unverifiedIdentityEntries) entries with unknown identity") }
            lines.append("  cache inventory: \(summary.cacheEntries) entries, \(summary.cacheUniqueFiles) unique files, \(summary.cacheDocumentBytes) bytes; excluded from directory totals")
        }
        lines.append("Deduplicated inventory estimates, not effective session context. Same-name selection and actual loading are not inferred.")
        for summary in report.qualitySummaries ?? [] {
            let scope = summary.scope == "cache" ? "cache inventory; loading unverified" : "directory/configured plugins"
            lines.append("\(summary.host) content evidence [\(scope)]: \(summary.inspectedFiles)/\(summary.uniqueFiles) unique files inspected · \(summary.aliases) alias entries excluded")
            lines.append("  \(summary.checkedLocalReferences) local references checked · \(summary.findings) findings · \(summary.incompleteInspections) incomplete inspections")
            lines.append("  excluded from content totals: \(summary.unavailableFiles) files without evidence · \(summary.conflictingFiles) conflicting files · \(summary.unverifiedIdentityEntries) entries with unknown identity · \(summary.unmeasuredEntries) unmeasured entries")
        }
        lines.append("")
        for item in report.skills {
            lines.append(style.bold(item.name) + style.dim(" [" + item.agent + "]"))
            if item.skillFootprint?.scope == "cache" {
                lines.append("  cache version; loading unverified; configured enabled: " + (item.skillFootprint?.pluginConfiguredEnabled.map(String.init) ?? "unknown"))
            }
            lines.append("  " + (item.skillFootprint?.summary ?? "Content not measured"))
            if let error = item.skillFootprint?.catalog.referenceError { lines.append("  catalog measurement unavailable: " + error) }
            if let error = item.skillFootprint?.document.referenceError { lines.append("  reference count unavailable: " + error + "; heuristic retained separately") }
            if let source = item.skillFootprint?.sourcePath ?? item.source { lines.append("  " + style.dim(source)) }
        }
        lines += ["", style.bold("MCP · \(report.mcpServers.count) configuration entries"), report.mcpNote]
        for finding in report.findings { lines.append("  \(finding.severity.symbol) \(finding.subject): \(finding.message)") }
        if report.cancelled { lines.append("Inspection stopped; results are incomplete.") }
        out(lines)
    }

    func required(_ name: String?, _ sub: String) throws -> String {
        guard let name, !name.isEmpty else { throw CLIError("usage: thermo agents \(sub) NAME (see thermo agents list)") }
        return name
    }

    /// Items called `name` (or with that id), narrowed by --area / --agent.
    func select(_ name: String, in report: DoctorReport) throws -> [AgentItem] {
        var items = report.items.filter { $0.id == name || $0.name.caseInsensitiveCompare(name) == .orderedSame }
        if items.isEmpty {  // also accept a unique prefix such as "codex-computer"
            items = report.items.filter { $0.name.lowercased().hasPrefix(name.lowercased()) }
        }
        if let a = app.args.options["area"] {
            guard let area = Area(rawValue: a) else {
                throw CLIError("unknown area '\(a)'; areas: " + Area.allCases.map(\.rawValue).joined(separator: ", "))
            }
            items = items.filter { $0.area == area }
        }
        if let agent = app.args.options["agent"] { items = items.filter { $0.agent.caseInsensitiveCompare(agent) == .orderedSame } }
        guard !items.isEmpty else { throw CLIError("no item named '\(name)' (see thermo agents list)") }
        return items
    }

    func describe(_ i: AgentItem) -> String {
        "\(i.name)  [\(i.area.rawValue)\(i.agent == "system" ? "" : ", " + i.agent)]" + (i.source.map { "  " + $0 } ?? "")
    }

    /// Everything about one item, with its actions numbered for `run --action N`.
    func show(_ name: String) throws {
        let report = AgentDoctor.run(try environment())
        let items = try select(name, in: report)
        if app.args.has("json") {
            struct Shown: Encodable { let item: AgentItem; let findings: [Finding] }
            print(Export.diagnosticJSON(items.map { Shown(item: $0, findings: report.findings(for: $0)) }))
            return
        }
        if app.args.has("csv") {
            let ids = Set(items.map(\.id))
            print(Export.diagnosticCSV(items: items, findings: report.findings.filter { $0.item.map(ids.contains) == true }, generated: report.generated))
            return
        }
        var lines: [String] = []
        for i in items {
            let status = !i.enabled ? style.dim("off") : i.severity == .error ? style.red("error") : i.severity == .warning ? style.yellow("warning")
                : i.severity == .info ? style.dim("note") : style.green("OK")
            lines.append(style.bold(i.name) + "  " + status + style.dim("  \(i.area.rawValue)" + (i.agent == "system" ? "" : " · \(i.agent)")))
            lines.append("  " + i.detail)
            if let footprint = i.skillFootprint {
                lines.append("  " + footprint.summary)
                lines.append(style.dim("  " + SkillFootprint.caveat))
            }
            if let src = i.source { lines.append(style.dim("  " + src)) }
            lines.append(style.dim("  id: \(i.id)"))
            for f in report.findings(for: i) {
                lines.append("  " + (f.severity == .error ? style.red("✗ ") : f.severity == .warning ? style.yellow("! ") : style.dim("· ")) + f.message)
                if let fix = f.fix { lines.append("    " + style.cyan("→ " + fix)) }
            }
            if i.actions.isEmpty {
                lines.append(style.dim("  no actions (managed by its plugin or the system)"))
            } else {
                lines.append("  actions:")
                for (n, a) in i.actions.enumerated() {
                    lines.append("    \(n + 1). " + style.bold(a.title) + style.dim("  (\(a.kind.rawValue)\(a.destructive ? ", destructive" : "")\(a.bulk ? "" : ", interrupts something in use"))"))
                    lines.append("       " + a.summary)
                    for st in a.steps { lines.append("       " + style.cyan("$ ") + st.display) }
                }
            }
            lines.append("")
        }
        out(lines)
    }

    /// One action on the item(s) called `name`: the first action of `kind`, or --action N.
    func act(on name: String, kind: ActionKind?) throws {
        let env = try environment()
        let report = AgentDoctor.run(env)
        let items = try select(name, in: report)
        if items.count > 1 && !app.args.has("all") {
            throw CLIError("'\(name)' matches \(items.count) items; narrow with --area/--agent, use the id, or add --all:\n  "
                           + items.map(describe).joined(separator: "\n  "))
        }
        var plans: [(AgentItem, Action)] = []
        for item in items {
            let action: Action?
            if let n = app.args.options["action"] {
                guard let k = Int(n), k >= 1, k <= item.actions.count else {
                    throw CLIError("\(item.name) has \(item.actions.count) action(s); see thermo agents show \"\(item.name)\"")
                }
                action = item.actions[k - 1]
            } else if let kind {
                // A broken item has only a fix that removes it (a dead symlink, a job whose program is gone);
                // for those, uninstalling is that fix.
                action = item.actions.first { $0.kind == kind }
                    ?? (kind == .uninstall ? item.actions.first { a in
                        a.kind == .fix && a.steps.allSatisfy {
                            switch $0 { case .unlink, .trash, .bootout: return true; default: return false }
                        }
                    } : nil)
            } else {
                throw CLIError("usage: thermo agents run NAME --action N (see thermo agents show NAME)")
            }
            guard let action else {
                let available = item.actions.map { $0.kind.rawValue }
                throw CLIError("\(item.name) has no \(kind?.rawValue ?? "such") action"
                               + (available.isEmpty ? " (it is managed by its plugin or the system)" : "; available: " + available.joined(separator: ", ")))
            }
            plans.append((item, action))
        }
        try apply(plans, env: env)
    }

    /// Plugins and skills with a newer version. Plugin versions come from the marketplace
    /// catalogs Claude Code keeps; `--check` first asks GitHub about skills and caches the answer.
    func updates() throws {
        let env = try environment()
        var checked: SkillUpdateCache?
        if app.args.has("check") {
            if !app.args.has("json") { FileHandle.standardError.write(Data("checking skills on GitHub…\n".utf8)) }
            let cache = SkillUpdates.check(env)
            cache.save(home: env.home)
            checked = cache
        }
        let report = AgentDoctor.run(env)
        let rows = report.items.filter { $0.update != nil }
        struct Row: Encodable { let name: String; let area: String; let agent: String; let installed: String; let available: String; let id: String }
        struct Output: Encodable { let updates: [Row]; let skillsChecked: Date?; let skillsUnchecked: [String: String] }
        let cache = checked ?? SkillUpdateCache.load(home: env.home)
        let out = Output(updates: rows.map { Row(name: $0.name, area: $0.area.rawValue, agent: $0.agent, installed: $0.update!.installed,
                                               available: $0.update!.available, id: $0.id) },
                         skillsChecked: cache?.checked, skillsUnchecked: cache?.failed ?? [:])
        if app.args.has("json") { print(Export.json(out)); return }
        if rows.isEmpty { print(tr("everything is up to date")) }
        for r in out.updates { print("\(r.name)  [\(r.area), \(r.agent)]  \(r.installed) → \(r.available)") }
        if let checked = cache?.checked {
            print(tr("skills last checked %1$@; thermo agents updates --check to check again", checked.formatted(date: .abbreviated, time: .shortened)))
        } else {
            print(tr("skills not checked yet: thermo agents updates --check"))
        }
        if !rows.isEmpty { print(tr("thermo agents update NAME, or thermo agents update for all of them")) }
    }

    func updateAll() throws {
        let env = try environment()
        let report = AgentDoctor.run(env)
        let plans = report.items.compactMap { item in item.actions.first { $0.kind == .update }.map { (item, $0) } }
        if plans.isEmpty {
            if app.args.has("json") { print(Export.json(ActionReport(dryRun: app.args.has("dry-run"), complete: true, plans: [], results: []))) }
            else { print(tr("everything is up to date")) }
            return
        }
        try apply(plans, env: env)
    }

    /// Every bulk-safe automatic fix for items with an error or warning.
    func fixAll() throws {
        let env = try environment()
        let report = AgentDoctor.run(env)
        let plans = report.items.filter { $0.severity == .error || $0.severity == .warning }
            .compactMap { item in item.actions.first { $0.kind == .fix && $0.bulk }.map { (item, $0) } }
        if plans.isEmpty {
            if app.args.has("json") { print(Export.json(ActionReport(dryRun: app.args.has("dry-run"), complete: true, plans: [], results: []))) }
            else { print("nothing to fix automatically" + (report.count(.error) + report.count(.warning) > 0 ? " (see thermo agents for manual fixes)" : "")) }
            return
        }
        try apply(plans, env: env)
    }

    /// Shows exactly what will run, asks (unless --yes), runs, then rescans.
    struct ActionPlan: Encodable { let name: String; let title: String; let summary: String; let destructive: Bool; let steps: [String] }
    struct ActionResultRow: Encodable { let name: String; let succeeded: Bool; let log: [String]; let backups: [String] }
    struct ActionReport: Encodable { let dryRun: Bool; let complete: Bool; let plans: [ActionPlan]; let results: [ActionResultRow]; var observedAfter: DoctorReport? = nil }
    func apply(_ plans: [(AgentItem, Action)], env: DoctorEnvironment, write: (String) -> Void = { print($0) }) throws {
        let review = plans.map { item, action in ActionPlan(name: Redact.text(item.name), title: action.title, summary: action.summary, destructive: action.destructive, steps: action.steps.map(\.display)) }
        if app.args.has("dry-run") {
            if app.args.has("json") { write(Export.json(ActionReport(dryRun: true, complete: true, plans: review, results: []))) }
            else { out(review.flatMap { [$0.name + " · " + $0.title, $0.summary] + $0.steps }) }
            return
        }
        if !app.args.has("json") { out(review.flatMap { [$0.name + " · " + $0.title, $0.summary] + $0.steps }) }
        try app.approveAction("Apply the reviewed Agent actions? Configuration files are backed up first.")
        var results: [ActionResultRow] = []
        for (item, action) in plans {
            let result = ActionRunner.perform(action, env: env)
            results.append(.init(name: Redact.text(item.name), succeeded: result.ok, log: result.log.map(Redact.text), backups: result.backups))
        }
        let complete = results.allSatisfy(\.succeeded)
        var afterEnvironment = env; afterEnvironment.now = Date()
        let after = AgentDoctor.run(afterEnvironment)
        if app.args.has("json") { write(Export.diagnosticJSON(ActionReport(dryRun: false, complete: complete, plans: review, results: results, observedAfter:after))) }
        else { for result in results { out([result.name + (result.succeeded ? " · succeeded" : " · failed")] + result.log) }; print("after: " + after.headline) }
        if !complete { throw CLIError("Some Agent actions failed; inspect results and backups.", exitCode: 3) }
    }

    func title(_ c: Area) -> String {
        switch c {
        case .hooks: return "Hooks"
        case .mcp: return "MCP servers"
        case .plugins: return "Plugins"
        case .skills: return "Skills"
        case .statusline: return "Status line"
        case .launchd: return "Launch agents"
        case .processes: return "Processes"
        case .worktrees: return "Worktrees"
        }
    }
}
