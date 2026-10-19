import CleanKit
import Foundation

/// `thermo clean`: scan (read-only) and `thermo clean run`: remove selected items.
struct CleanCommand {
    let app: App
    var style: Style { app.style }
    var args: Args { app.args }

    /// Each line is a complete JSON event; concurrent scanner callbacks never interleave writes.
    final class ScanStream {
        struct Event: Encodable {
            var event: String
            var step: String? = nil
            var freeBytes: Int64? = nil
            var capacityBytes: Int64? = nil
            var items: [CleanItem]? = nil
            var entry: SpaceOverview.Entry? = nil
            var report: ScanReport? = nil
            var overview: SpaceOverview? = nil
        }
        let lock = NSLock()
        let write: (Data) -> Void
        init(write: @escaping (Data) -> Void = { FileHandle.standardOutput.write($0) }) { self.write = write }
        func emit(_ event: Event) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            guard var data = try? encoder.encode(event) else { return }
            data.append(10)
            lock.lock(); defer { lock.unlock() }
            write(data)
        }
        func start() {
            let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey])
            emit(Event(event: "started", freeBytes: values?.volumeAvailableCapacity.map(Int64.init),
                       capacityBytes: values?.volumeTotalCapacity.map(Int64.init)))
        }
    }

    func run(_ rest: [String]) throws {
        if args.options["budget"] != nil || args.options["timeout"] != nil, (rest.first == "log" || (rest.first == "run" && !args.has("dry-run"))) {
            throw CLIError("--budget is for read-only scans")
        }
        if args.has("stream") {
            guard !args.has("csv"), !["run", "log", "empty-trash", "restore", "repair-worktrees", "whitelist"].contains(rest.first ?? "") else {
                throw CLIError("--stream is for read-only scans and cannot be combined with --csv")
            }
        }
        switch rest.first {
        case "run": try clean(Array(rest.dropFirst()))
        case "plan": try savePlan(Array(rest.dropFirst()))
        case "apply": try applyPlan(Array(rest.dropFirst()))
        case "log": showLog()
        case "whitelist": try whitelist(Array(rest.dropFirst()))
        case "empty-trash": try emptyTrash(Array(rest.dropFirst()))
        case "restore": try restoreBatch(Array(rest.dropFirst()))
        case "repair-worktrees":
            guard rest.count == 1 else { throw CLIError("repair-worktrees takes --root REPO, not positional paths") }
            try repairWorktrees()
        case "overview", "space": try overview()
        default: try report(filter: rest)
        }
    }

    static func budget(_ args: Args) throws -> TimeInterval? {
        guard !(args.options["budget"] != nil && args.options["timeout"] != nil) else { throw CLIError("choose --budget or --timeout") }
        let value = try args.double("budget") ?? args.double("timeout")
        if let value, value > 86400 { throw CLIError("--budget must be at most 86400 seconds") }
        return value
    }

    static func deadline(after seconds: TimeInterval?, cancellation: ScanCancellation) -> DispatchWorkItem? {
        guard let seconds else { return nil }
        let item = DispatchWorkItem { cancellation.cancel() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: item)
        return item
    }

    func overview() throws {
        let cancellation = ScanCancellation()
        let deadline = Self.deadline(after: try Self.budget(args), cancellation: cancellation)
        defer { deadline?.cancel() }
        let stream = args.has("stream") ? ScanStream() : nil
        stream?.start()
        let tty = isatty(STDERR_FILENO) != 0 && !args.has("json") && stream == nil
        let o = SpaceOverview.measure(onProgress: { step in
            stream?.emit(.init(event: "progress", step: step))
            if tty { FileHandle.standardError.write(Data(".".utf8)) }
        }, onEntry: { entry in stream?.emit(.init(event: "entry", entry: entry)) }, cancellation: cancellation)
        if let stream { stream.emit(.init(event: "finished", overview: o)); o.save(); if o.cancelled == true { throw CLIError("Overview scan is incomplete.",exitCode:3) }; return }
        o.save()  // the app's Overview opens with these numbers
        if tty { FileHandle.standardError.write("\n".data(using: .utf8)!) }
        if args.has("json") { print(Export.json(o)); if o.cancelled == true { throw CLIError("Overview scan is incomplete.",exitCode:3) }; return }
        func gb(_ b: Int64) -> String { b >= 1_000_000_000 ? String(format: "%.1f GB", Double(b) / 1e9) : String(format: "%.0f MB", Double(b) / 1e6) }
        var lines = [style.bold("Disk") + style.dim(String(format: " · %@ used of %@ · %@ free", gb(o.used), gb(o.capacity), gb(o.free))
                     + (o.purgeable > 1_000_000_000 ? " (+\(gb(o.purgeable)) purgeable)" : "")), ""]
        for e in o.entries where e.bytes >= 100_000_000 || e.effectiveSizeState != .complete {
            lines.append(pad(e.sizeText, 18, right: true) + "  " + style.bold(e.title))
            if let n = e.note { lines.append(pad("", 11) + style.dim(n)) }
            if let a = e.action { lines.append(pad("", 11) + style.yellow("→ " + a)) }
            let children = Array(e.children.filter { $0.effectiveSizeState == .complete }.prefix(args.has("all") ? 20 : 5)) + e.children.filter { $0.effectiveSizeState != .complete }
            for c in children where c.bytes >= 100_000_000 || c.effectiveSizeState != .complete {
                lines.append(pad("", 11) + pad(c.sizeText, 18, right: true) + "  " + c.title + (c.action.map { style.dim("  → " + $0) } ?? ""))
            }
        }
        if let over = o.overcounted {
            lines.append(""); lines.append(style.dim(tr("The headings add up to %1$@ more than the disk uses: hard links (pnpm), APFS clones and files written while measuring count in each place.", gb(over))))
        }
        lines.append("")
        lines.append(style.dim(o.cancelled == true ? String(format: "stopped after %.1f s · completed folders counted; unfinished categories are lower bounds", o.duration)
                                                    : String(format: "measured in %.0f s · what can go: thermo clean", o.duration)))
        out(lines)
    }

    func options() throws -> ScanOptions {
        var o = ScanOptions()
        o.exactSizes = args.has("exact")
        if let v = args.options["older-than"] {
            guard let d = parseDays(v) else { throw CLIError("--older-than expects days like 30, 2w, 6m or 1y; got '\(v)'") }
            o.olderThanDays = d
            o.sessionRetentionDays = d
        }
        if let roots = args.options["root"] {
            o.discoverProjectRoots = false
            o.projectRoots = roots.split(separator: ",").map { FS.expand(String($0)) }
                .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        }
        return o
    }

    func scan(_ categories: Set<CleanCategory>? = nil, onlyIDs: Set<String>? = nil) throws -> ScanReport {
        var o = try options()
        if let categories { o.categories = categories }
        o.onlyIDs = onlyIDs
        let scanner = DiskScanner(options: o)
        let deadline = Self.deadline(after: try Self.budget(args) ?? 60, cancellation: scanner.cancellation)
        defer { deadline?.cancel() }
        let stream = args.has("stream") ? ScanStream() : nil
        stream?.start()
        if let stream {
            scanner.onItems = { stream.emit(.init(event: "items", items: $0)) }
            scanner.onProgress = { stream.emit(.init(event: "progress", step: $0)) }
        }
        let progress = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        let progressStarted = Date()
        FileHandle.standardError.write(Data("scanning… budget \(try Self.budget(args) ?? 60)s; JSON results arrive when finished (--stream for events)\n".utf8))
        progress.schedule(deadline: .now() + 5, repeating: 5)
        progress.setEventHandler {
            FileHandle.standardError.write(Data(String(format: "scanning… %.0fs elapsed\n", Date().timeIntervalSince(progressStarted)).utf8))
        }
        progress.resume()
        defer { progress.cancel() }
        let existing = scanner.onProgress
        scanner.onProgress = { step in
            existing?(step)
            FileHandle.standardError.write(Data("scan: \(step)\n".utf8))
        }
        let r = scanner.scan()
        stream?.emit(.init(event: "finished", report: r))
        FileHandle.standardError.write(Data("scan finished: \(r.items.count) items; partial=\(r.cancelled)\n".utf8))
        return r
    }

    /// Positional filters: category names, `ai`, or id prefixes.
    func categories(for filter: [String]) throws -> Set<CleanCategory>? {
        guard !filter.isEmpty else { return nil }
        var set = Set<CleanCategory>()
        for f in filter {
            if f == "ai" { set.formUnion(CleanCategory.allCases.filter(\.isAI)) }
            else if let c = CleanCategory(rawValue: f) { set.insert(c) }
            else if f == "sessions" { set.insert(.aiSessions) }
            else if f == "worktrees" { set.insert(.agentWorktrees) }
            else if f == "models" { set.insert(.aiModels) }
            else {
                throw CLIError("unknown category '\(f)'; use ai, " + CleanCategory.allCases.map(\.rawValue).joined(separator: ", "))
            }
        }
        return set
    }

    // MARK: report

    func report(filter: [String]) throws {
        let cats = try categories(for: filter)
        let r = try scan(cats)
        try writeReport(r, categories: cats)
    }

    func writeReport(_ r: ScanReport, categories cats: Set<CleanCategory>?, write: (String) -> Void = { print($0) }) throws {
        renderReport(r, categories: cats, write: write)
        if r.cancelled { throw CLIError("Scan is incomplete; emitted results remain partial.", exitCode: 3) }
    }

    static func emptyScanMessage(_ r: ScanReport) -> String {
        switch r.resultState {
        case .empty: return "nothing to clean"
        case .stopped: return "no findings before the scan stopped; results are partial"
        case .incomplete: return "no verified findings; some locations, rules or sizes could not be checked"
        case .kept: return "items were kept; review their reasons"
        case .found, .review: return "review the available scan results"
        }
    }

    private func renderReport(_ r: ScanReport, categories cats: Set<CleanCategory>?, write: (String) -> Void) {
        if args.has("stream") { return } // scan() already emitted the finished event.
        if args.has("json") { write(Export.json(r)); return }
        if args.has("csv") {
            write("id,category,safety,bytes,files,last_used,title,detail,blocked")
            let f = ISO8601DateFormatter()
            for i in r.items {
                write([i.id, i.category.rawValue, i.safety.rawValue, String(i.bytes), String(i.files),
                       i.lastUsed.map(f.string) ?? "", i.title, i.detail, i.blocked ?? ""].map(Export.csvField).joined(separator: ","))
            }
            return
        }
        let showAll = args.has("all") || cats != nil
        let amount = ByteFormat.string(r.totalBytes)
        let displayedAmount = r.resultState == .empty || r.resultState == .found ? style.green(amount) : style.yellow(amount)
        var lines = [style.bold("thermo clean") + style.dim(" · ") + displayedAmount + style.dim(" in file-size estimates (not guaranteed reclaimed) · scanned in \(String(format: "%.1f", r.duration)) s · nothing was deleted")]
        if r.sessionRetentionDays == nil { lines.append(tr("All conversations are kept. Add --older-than to review old sessions.")) }
        if let c = r.spaceContext {
            func value(_ bytes: Int64?) -> String { bytes.map(ByteFormat.string) ?? "unknown" }
            lines.append("Swap files: " + value(c.swapFiles) + " (used " + value(c.swapUsed) + "); simulator runtime images: " + value(c.simulatorRuntimes) + "; purgeable estimate: " + value(c.purgeable))
            lines.append(style.dim(c.note))
        }
        if let since = r.changesSince, let growth = r.growth {
            lines.append("Changes since " + ISO8601DateFormatter().string(from: since) + " (same scan scope):")
            for change in growth.prefix(10) {
                lines.append("  " + (change.changeBytes > 0 ? "+" : "−") + ByteFormat.string(abs(change.changeBytes)) + "  " + change.title)
            }
            if growth.isEmpty { lines.append("  no measured size changes") }
        }
        let width = min(terminalWidth(), 140)
        for c in CleanCategory.allCases {
            let items = r.items.filter { $0.category == c }
            guard !items.isEmpty else { continue }
            lines.append("")
            let waiting = r.blockedBytes(in: c)
            lines.append(pad(style.bold(c.title), 0) + style.dim("  " + ByteFormat.string(r.bytes(in: c)))
                         + (waiting > 0 ? style.yellow("  + " + tr("%1$@ held back (see skipped)", ByteFormat.string(waiting))) : ""))
            let shown = showAll ? items : Array(items.prefix(6))
            for i in shown { lines += render(i, width: width) }
            if shown.count < items.count {
                let more = items.dropFirst(shown.count)
                lines.append(style.dim("  + \(more.count) more (\(ByteFormat.string(more.reduce(0) { $0 + $1.bytes }))) · thermo clean \(c.rawValue)"))
            }
        }
        if r.cancelled { lines.append(style.yellow("scan stopped · completed findings only; results are incomplete")) }
        else if r.resultState == .incomplete { lines.append(style.yellow("scan incomplete · some locations, rules or sizes could not be checked")) }
        if let why = r.whitelistError { lines.append(style.red(why + " · " + tr("cleanup is disabled until it is fixed"))) }
        if r.items.isEmpty {
            lines.append("")
            lines.append(style.dim("  " + Self.emptyScanMessage(r)))
        }
        if let days = r.claudeCleanupDays {
            lines.append("")
            lines.append(style.dim("Claude Code deletes its own sessions after \(days) days (cleanupPeriodDays in ~/.claude/settings.json)."))
        }
        if !r.denied.isEmpty {
            lines.append(style.yellow("\(r.denied.count) location\(r.denied.count == 1 ? "" : "s") could not be read") +
                         style.dim(" — give your terminal Full Disk Access (System Settings → Privacy & Security) to include them"))
        }
        let safe = r.select(["safe"]).filter(\.cleanable)
        lines.append("")
        lines.append(style.dim("Clean:  ") + "thermo clean run safe" + style.dim("   the \(safe.count) safe items (\(ByteFormat.string(safe.reduce(0) { $0 + $1.bytes })))"))
        lines.append(style.dim("        ") + "thermo clean run ID…" + style.dim("    items by id, id prefix or category; review items go to the Trash"))
        lines.append(style.dim("        ") + "thermo clean run ID#SESSION" + style.dim("  just some sessions of an item (see --all)"))
        write(lines.joined(separator: "\n"))
    }

    func badge(_ s: Safety) -> String {
        switch s {
        case .safe: return style.green("safe  ")
        case .review: return style.yellow("review")
        case .risky: return style.red("risky ")
        }
    }

    func render(_ i: CleanItem, width: Int) -> [String] {
        let mark = i.paths.isEmpty ? style.cyan("info  ") : badge(i.safety)
        var head = "  " + pad(ByteFormat.string(i.bytes), 8, right: true) + "  " + mark + "  " + i.title
        if let used = i.lastUsed { head += style.dim("  " + AgeFormat.string(used)) }
        var lines = [head]
        let indent = String(repeating: " ", count: 20)
        var sub = [style.cyan(i.id), i.detail].filter { !$0.isEmpty }.joined(separator: style.dim(" · "))
        if !sub.isEmpty { sub = indent + sub; lines.append(sub) }
        if let b = i.blocked { lines.append(indent + style.red("skipped: " + b)) }
        else if let kept = i.whitelisted { lines.append(indent + style.dim(tr("%1$@ whitelisted paths kept", String(kept.count)))) }
        if let n = i.note {
            let limit = max(40, width - 22)
            lines.append(indent + style.dim(n.count > limit ? String(n.prefix(limit - 1)) + "…" : n))
        }
        if i.sizeIncomplete == true { lines.append(indent + style.yellow("size is a lower bound; large tree scan was limited")) }
        else if i.estimatedSize == true { lines.append(indent + style.dim("allocated size estimate; shared blocks may not be reclaimed")) }
        if let h = i.hint { lines.append(indent + style.dim("run: ") + h) }
        if let native = i.native, !native.runs.isEmpty { lines.append(indent + style.dim(tr("runs `%1$@`", native.display))) }
        if args.has("all"), let parts = i.parts, parts.count > 1 {
            for p in parts {
                lines.append(indent + "  " + pad(ByteFormat.string(p.bytes), 8, right: true) + "  " + style.cyan("#" + p.id)
                             + style.dim("  " + AgeFormat.string(p.lastUsed) + "  ") + String(p.title.prefix(60)))
            }
        }
        return lines
    }

    // MARK: run

    /// The item ids named by a selection (`ID` or `ID#SESSION`), or nil when any selector is a
    /// group (all, safe, ai, a category) that has to be found by scanning.
    static func normalizedSelectors(_ selectors: [String]) -> [String] {
        let aliases = ["sessions": CleanCategory.aiSessions.rawValue, "worktrees": CleanCategory.agentWorktrees.rawValue, "models": CleanCategory.aiModels.rawValue]
        return selectors.map { aliases[$0.lowercased()] ?? $0 }
    }

    static func itemIDs(in selectors: [String]) -> Set<String>? {
        var ids = Set<String>()
        for selector in normalizedSelectors(selectors) {
            let s = selector.lowercased()
            if ["all", "safe", "ai"].contains(s) || CleanCategory(rawValue: s) != nil || s.hasSuffix("*") { return nil }
            ids.insert(String(s.split(separator: "#", maxSplits: 1).first ?? Substring(s)))
        }
        return ids.isEmpty ? nil : ids
    }

    static func cleanupCategories(for selectors: [String]) -> Set<CleanCategory>? {
        var categories = Set<CleanCategory>()
        for selector in normalizedSelectors(selectors) {
            let s = selector.lowercased()
            if ["all", "safe"].contains(s) { return nil }
            if s == "ai" { categories.formUnion(CleanCategory.allCases.filter(\.isAI)); continue }
            if let category = CleanCategory(rawValue: s) { categories.insert(category); continue }
            if ["claude-sessions", "codex-sessions", "gemini-sessions", "cline-tasks", "roo-code-tasks", "kilo-code-tasks", "roo-tasks", "kilo-tasks"].contains(where: { s == $0 || s.hasPrefix($0 + "/") }) {
                categories.insert(.aiSessions); continue
            }
            if ["claude-orphans", "claude-project-backups"].contains(s) || s.hasSuffix("-orphan-workspaces") { categories.insert(.aiSessions); continue }
            if s.hasPrefix("project/") { categories.insert(.projects); continue }
            if s.hasPrefix("worktree/") { categories.insert(.agentWorktrees); continue }
            if s.hasPrefix("simulator-") { categories.insert(.xcode); continue }
            if let rule = Rules.paths.first(where: { $0.id == s }) { categories.insert(rule.category); continue }
            return nil
        }
        return categories
    }

    func clean(_ requested: [String]) throws {
        let selectors = Self.normalizedSelectors(requested)
        guard !selectors.isEmpty else {
            throw CLIError("usage: thermo clean run safe|all|ai|CATEGORY|ID… [--older-than 30d] [--trash|--permanent] [--yes]")
        }
        if args.has("trash") && args.has("permanent") { throw CLIError("--trash and --permanent are exclusive") }
        if try options().sessionRetentionDays == nil, Self.cleanupCategories(for: selectors) == Set([.aiSessions]) {
            throw CLIError(tr("All conversations are kept. Add --older-than to review old sessions."))
        }
        let mode: RemovalMode = args.has("permanent") ? .permanent : args.has("trash") ? .trash : .auto
        // Project folders are the slow part; only walk them when the selection can include build output.
        let needsProjects = selectors.contains { ["all", "safe", "projects"].contains($0) || $0.hasPrefix("project") }
        let r: ScanReport
        var picked: [CleanItem]
        if !args.has("rescan"), let cached = try reusableReport(for: selectors) {
            // A recent scan answers this selection: re-check just the chosen items instead of
            // scanning everything again (minutes on a busy disk).
            r = cached.report
            picked = cached.picked
            if !args.has("json") {
                print(style.dim("using the scan from \(AgeFormat.string(r.started)); sizes are from then (--rescan to scan again)"))
            }
        } else {
            r = try scan(Self.cleanupCategories(for: selectors) ?? (needsProjects ? nil : Set(CleanCategory.allCases.filter { $0 != .projects })),
                         onlyIDs: Self.itemIDs(in: selectors))
            picked = r.select(selectors)
        }
        let missing = selectors.filter { r.select([$0]).isEmpty }
        try execute(report: r, picked: picked, mode: mode, missingSelectors: missing)
    }

    struct Preview: Encodable {
        let dryRun = true
        let scannedAt: Date
        let scanCancelled: Bool
        let removalMode: String
        let items: [PreviewItem]
        let skipped: [CleanItem]
        var sessionRetentionDays: Int? = nil
        var sessionPolicyVersion: Int? = nil
        var missingSelectors: [String] = []
    }

    struct ExecutionReport: Encodable {
        let schemaVersion = 2
        let outcome: String
        let complete: Bool
        let scanComplete: Bool
        let results: [CleanResult]
        let skipped: [CleanItem]
        let missingSelectors: [String]
        let spaceObservation: DiskSpaceObservation
        let estimatedDeletedBytes: Int64
        let trashedBytes: Int64
    }
    struct PreviewItem: Encodable {
        let item: CleanItem
        let action: String
        /// The exact tool command lines that would run instead of deleting their folders.
        var commands: [String]? = nil
    }

    /// The reviewed execution boundary is shared by real execution and dry-run tests.
    func execute(report r: ScanReport, picked: [CleanItem], mode: RemovalMode, missingSelectors: [String] = [],
                 write: (String) -> Void = { print($0) }) throws {
        guard !picked.isEmpty else {
            if args.has("dry-run"), r.cancelled {
                if args.has("json") {
                    write(Export.json(Preview(scannedAt: r.started, scanCancelled: true, removalMode: mode.rawValue,
                                              items: [], skipped: [], sessionRetentionDays: r.sessionRetentionDays, sessionPolicyVersion: r.sessionPolicyVersion)))
                } else { write("dry run · scan stopped before any matching item completed; nothing was removed") }
                return
            }
            throw CLIError("nothing matches; see thermo clean")
        }
        // A saved scan can predate a whitelist edit; an unreadable whitelist stops the run.
        let whitelist: Whitelist
        do { whitelist = try Whitelist.loadForRemoval() } catch { throw CLIError(Whitelist.unreadable(error) + "; nothing was removed") }
        let processes = ProcessTable.current(.init(cpu: false))
        let reviewed = picked.map { original -> CleanItem in
            var item = whitelist.apply(original)
            item.blocked = Cleaner.refusal(item, mode: mode, processes: processes)
            return item
        }
        let todo = reviewed.filter(\.cleanable)
        let skipped = reviewed.filter { !$0.cleanable }
        let total = todo.reduce(Int64(0)) { $0 + $1.bytes }

        var plan = [style.bold("About to clean \(ByteFormat.string(total)) in \(todo.count) item\(todo.count == 1 ? "" : "s"):")]
        for i in todo {
            let native = i.runsNativeClean(mode) ? i.native : nil
            let how = native != nil ? style.red("tool clean") : !(i.commands ?? []).isEmpty ? style.red("tool removal") : mode.trashes(i.safety) ? style.yellow("trash ") : style.red("delete")
            // Paths a tool command takes over are not deleted; the review names the command instead.
            let deleted = i.paths.filter { native?.owns($0) != true }.count
            plan.append("  " + pad(ByteFormat.string(i.bytes), 8, right: true) + "  " + how + "  " + i.title
                        + (native == nil || deleted > 0 ? style.dim("  \(deleted) path\(deleted == 1 ? "" : "s")") : "")
                        + (i.whitelisted.map { style.dim(" · " + tr("%1$@ whitelisted paths kept", String($0.count))) } ?? ""))
            if let native {
                plan.append(style.dim("            " + tr("runs `%1$@`", native.display)))
                for run in native.runs { plan.append(style.dim("              " + run.commandLine)) }
            } else if let why = i.native?.fallback, !mode.trashes(i.safety) {
                plan.append(style.dim("            " + why))
            }
        }
        for item in todo {
            for path in item.commandScope ?? [] { plan.append("    " + tr("Tool-managed locations") + ": " + FS.tilde(path)) }
        }
        for i in skipped {
            plan.append(style.dim("  skipped  \(i.title): \(i.blocked ?? (i.hint.map { "run \($0)" } ?? "nothing to remove"))"))
        }
        if args.has("dry-run") {
            if args.has("json") {
                write(Export.json(Preview(scannedAt: r.started, scanCancelled: r.cancelled, removalMode: mode.rawValue,
                                          items: todo.map { PreviewItem(item: $0, action: $0.runsNativeClean(mode) ? "tool-clean" : !($0.commands ?? []).isEmpty ? "tool-removal" : mode.trashes($0.safety) ? "trash" : "delete",
                                                                       commands: $0.runsNativeClean(mode) ? $0.native?.runs.map(\.commandLine) : nil) },
                                          skipped: skipped, sessionRetentionDays: r.sessionRetentionDays, sessionPolicyVersion: r.sessionPolicyVersion, missingSelectors: missingSelectors)))
            } else {
                write(plan.joined(separator: "\n"))
                write("dry run · no files removed and no cleanup commands executed")
            }
            return
        }
        if args.has("json") == false { out(plan) }
        guard !todo.isEmpty else {
            if args.has("json") {
                write(Export.json(ExecutionReport(outcome: "refused", complete: false, scanComplete: !r.cancelled,
                    results: [], skipped: skipped, missingSelectors: missingSelectors,
                    spaceObservation: .init(before: nil, after: nil), estimatedDeletedBytes: 0, trashedBytes: 0)))
            }
            throw CLIError("No selected item could be cleaned; inspect skipped items.", exitCode: 3)
        }

        if !args.has("yes") {
            guard !args.has("json"), isatty(STDIN_FILENO) != 0 else { throw CLIError("Review --dry-run, then add --yes to confirm") }
            print("Proceed? [y/N] ", terminator: "")
            fflush(stdout)
            guard let answer = readLine(), ["y", "yes"].contains(answer.lowercased()) else { print("cancelled"); return }
        }

        let spaceBefore = DiskSpaceSnapshot.measure()
        var results: [CleanResult] = []
        let batchID = UUID().uuidString
        for i in todo {
            let res = Cleaner.clean(i, mode: mode, scannedAt: r.started, batchID: batchID)
            results.append(res)
            if !args.has("json") {
                let ok = res.failed.isEmpty
                print("  " + (ok ? style.green("✓") : style.yellow("!")) + " " + pad(ByteFormat.string(res.bytes), 8, right: true) + "  " + i.title
                      + (res.trashed ? style.dim("  (Trash)") : "")
                      + (res.outcome == "partial" ? "  (partially completed; remainder kept)" : "")
                      + (res.bytesIncomplete == true ? "  (removed-size estimate incomplete)" : ""))
                for (p, why) in res.failed.sorted(by: { $0.key < $1.key }).prefix(5) { print(style.dim("      \(FS.tilde(p)): \(why)")) }
                for p in (res.whitelisted ?? []).prefix(5) { print(style.dim("      \(FS.tilde(p)): " + Whitelist.reason)) }
                // Failures are listed above with the other failed paths.
                for o in res.toolCommands ?? [] where o.status == "ran" || o.fellBack == true {
                    print(style.dim("      " + (o.status == "ran" ? tr("ran `%1$@`", o.command)
                        : tr("did not run `%1$@`; folder deleted instead", o.command) + (o.detail.map { ": " + $0 } ?? ""))))
                }
            }
        }
        let observation = DiskSpaceObservation(before: spaceBefore, after: DiskSpaceSnapshot.measure())
        let freed = results.filter { !$0.trashed }.reduce(Int64(0)) { $0 + $1.bytes }
        let trashed = results.filter(\.trashed).reduce(Int64(0)) { $0 + ($1.trashedAllocatedBytes ?? $1.bytes) }
        let complete = !r.cancelled && skipped.isEmpty && missingSelectors.isEmpty && results.allSatisfy { $0.failed.isEmpty }
        if args.has("json") {
            write(Export.json(ExecutionReport(outcome: complete ? "succeeded" : "partial", complete: complete, scanComplete: !r.cancelled,
                results: results, skipped: skipped, missingSelectors: missingSelectors, spaceObservation: observation,
                estimatedDeletedBytes: freed, trashedBytes: trashed)))
            if !complete { throw CLIError("Cleanup was partial; inspect the JSON report before another action.", exitCode: 3) }
            return
        }
        let estimateIncomplete = results.contains { $0.bytesIncomplete == true }
        var summary = estimateIncomplete
            ? (freed == 0 ? "removed size is unknown" : "measured removed size: \(ByteFormat.string(freed)); total size is unknown")
            : "deleted \(ByteFormat.string(freed)) (estimated file size)"
        if trashed > 0 {
            summary += ", \(ByteFormat.string(trashed)) still occupies Trash space; empty only this batch to attempt reclaiming it"
        }
        if results.contains(where: { $0.trashBatchID == batchID }) {
            print("Review this batch: thermo clean empty-trash \(batchID) --dry-run")
            print("Empty only this batch: thermo clean empty-trash \(batchID) --yes")
        }
        if results.contains(where: { $0.bytesIncomplete == true }) { summary += "; some removed sizes could not be measured completely" }
        print(observation.summary)
        print(style.bold(summary) + style.dim(" · log: \(FS.tilde(Cleaner.logURL.path))"))
        if !complete { throw CLIError("Cleanup was partial; inspect results before another action.", exitCode: 3) }
    }

    // MARK: whitelist

    struct WhitelistListing: Encodable {
        let file: String
        let entries: [String]
        let rejected: [Whitelist.Rejected]
        let removalAllowed: Bool
        let issue: String?
    }

    /// `thermo clean whitelist [add|remove PATH…]`: paths every cleanup keeps.
    func whitelist(_ rest: [String], home: String = NSHomeDirectory(), cwd: String = FileManager.default.currentDirectoryPath,
                   write: (String) -> Void = { print($0) }) throws {
        let usage = "usage: thermo clean whitelist [add|remove PATH…] [--json]"
        // Relative paths are taken from the current folder; ~ and absolute paths and globs as typed.
        let paths = rest.dropFirst().map { $0.hasPrefix("/") || $0.hasPrefix("~") ? $0 : cwd + "/" + $0 }
        do {
            switch rest.first {
            case nil, "list":
                guard rest.count <= 1 else { throw CLIError(usage) }
                let w = try Whitelist.load(home: home)
                if args.has("json") { write(Export.json(WhitelistListing(file: w.file, entries: w.entries, rejected: w.rejected, removalAllowed: w.removalIssue == nil, issue: w.removalIssue))); return }
                write(style.bold(tr("Whitelist")) + style.dim(" · " + FS.tilde(w.file, home: home)))
                if let issue = w.removalIssue { write(style.red(issue)) }
                else if w.entries.isEmpty { write(style.dim("  " + tr("nothing whitelisted; add paths with thermo clean whitelist add PATH…"))) }
                for e in w.entries { write("  " + FS.tilde(e, home: home)) }
                for r in w.rejected { write(style.yellow("  " + tr("line %1$@ ignored: %2$@ (%3$@)", String(r.line), r.text, tr(r.reason)))) }
            case "add", "remove", "rm":
                guard !paths.isEmpty else { throw CLIError(usage) }
                let adding = rest.first == "add"
                let changes = args.has("dry-run") ? try Whitelist.previewChange(Array(paths), adding: adding, home: home)
                    : adding ? try Whitelist.add(Array(paths), home: home) : try Whitelist.remove(Array(paths), home: home)
                if args.has("json") {
                    struct Change: Encodable { let dryRun: Bool; let action: String; let changed: [String] }
                    write(Export.json(Change(dryRun: args.has("dry-run"), action: adding ? "add" : "remove", changed: changes)))
                } else {
                    for p in changes { write((args.has("dry-run") ? "planned " : "") + (adding ? "+ " : "- ") + FS.tilde(p, home: home)) }
                }
            default: throw CLIError(usage)
            }
        } catch let e as CLIError { throw e } catch { throw CLIError(error.localizedDescription) }
    }

    func repairWorktrees() throws {
        guard let repo = args.options["root"], !repo.contains(",") else { throw CLIError("usage: thermo clean repair-worktrees --root REPO --dry-run|--yes") }
        guard args.options["budget"] == nil, args.options["timeout"] == nil else { throw CLIError("scan budgets do not apply to registration repair") }
        let entries = try WorktreeRegistrationRepair.inspect(repo: repo)
        if args.has("dry-run") || !args.has("json") {
            if args.has("json") { print(Export.json(entries)) }
            else { for entry in entries { print(entry.path + (entry.blocked.map { " · kept: " + $0 } ?? " · missing; registration can be backed up and removed")) } }
        }
        if args.has("dry-run") { return }
        guard args.has("yes") else { throw CLIError("review with --dry-run, then add --yes to confirm registration repair") }
        let results = WorktreeRegistrationRepair.repair(repo: repo, entries: entries)
        if args.has("json") { print(Export.json(results)) }
        else { for result in results { print(result.path + ": " + (result.error ?? "registration removed") + (result.backup.map { " · backup: " + $0 } ?? "")) } }
    }

    func emptyTrash(_ selectors: [String], home: String = NSHomeDirectory(), write: (String) -> Void = { print($0) }) throws {
        guard selectors.count == 1 else { throw CLIError("usage: thermo clean empty-trash BATCH --dry-run|--yes") }
        guard !args.has("budget"), args.options["budget"] == nil, args.options["timeout"] == nil else { throw CLIError("scan budgets do not apply to deleting Trash items") }
        let batch = try TrashBatches.load(selectors[0], home: home)
        struct Review: Encodable { let batch: TrashBatch; let refusals: [String: String]; let permanent = true; let dryRun: Bool }
        let refused = Dictionary(batch.entries.compactMap { e in TrashBatches.emptyRefusal(e, home: home).map { (e.destination, $0) } }, uniquingKeysWith: { a, _ in a })
        if args.has("dry-run") || !args.has("json") {
            if args.has("json") { write(Export.json(Review(batch: batch, refusals: refused, dryRun: args.has("dry-run")))) }
            else {
                write("Permanent removal of only this batch's Trash entries:")
                for entry in batch.entries { write("  " + entry.destination + (refused[entry.destination].map { " · skipped: " + $0 } ?? "")) }
            }
        }
        if args.has("dry-run") { return }
        if !args.has("yes") {
            guard !args.has("json"), isatty(STDIN_FILENO) != 0 else { throw CLIError("add --yes after reviewing the batch with --dry-run") }
            print("Permanently remove this batch? [y/N] ", terminator: ""); fflush(stdout)
            guard let answer = readLine(), ["y", "yes"].contains(answer.lowercased()) else { return }
        }
        let result = try TrashBatches.empty(batch.id, home: home, reviewIdentity: try TrashBatches.reviewIdentity(batch),
            reviewedDestinations: Set(batch.entries.filter { refused[$0.destination] == nil }.map(\.destination)))
        if args.has("json") { write(Export.json(result)); if !result.failed.isEmpty { throw CLIError("Trash emptying was partial; inspect results.",exitCode:3) }; return }
        write("deleted \(ByteFormat.string(result.bytes)) (estimated); \(result.outcome ?? "unknown")")
        for (path, reason) in result.failed.sorted(by: { $0.key < $1.key }) { write("  kept \(path): \(reason)") }
        for path in result.whitelisted ?? [] { write("  kept " + path + ": " + tr(Whitelist.reason)) }
        if let observation = result.spaceObservation { write(observation.summary) }
        if !result.failed.isEmpty { throw CLIError("Trash emptying was partial; inspect results.",exitCode:3) }
    }

    /// `thermo clean restore BATCH`: moves the batch's Trash items back to where they were.
    func restoreBatch(_ selectors: [String], home: String = NSHomeDirectory(), write: (String) -> Void = { print($0) }) throws {
        guard selectors.count == 1 else { throw CLIError("usage: thermo clean restore BATCH --dry-run|--yes") }
        guard args.options["budget"] == nil, args.options["timeout"] == nil else { throw CLIError("scan budgets do not apply to restoring Trash items") }
        let review = try TrashBatches.restore(id: selectors[0], home: home, dryRun: true)
        func lines(_ r: TrashRestore) -> [String] {
            r.items.map { i in
                (["restored", "alreadyRestored"].contains(i.status) ? "  " + style.green("✓") + " " : "  " + style.yellow("!") + " ") + FS.tilde(i.original)
                    + (i.reason.map { style.dim(" · " + Self.restoreStatus(i.status) + ": " + $0) } ?? "")
            }
        }
        if args.has("dry-run") || !args.has("json") {
            if args.has("json") { write(Export.json(review)) }
            else { write(style.bold(tr("Put this batch back where it was:"))); lines(review).forEach(write) }
        }
        if args.has("dry-run") { return }
        if !review.items.isEmpty, review.items.allSatisfy({ $0.status == "alreadyRestored" }) {
            var unchanged = review
            unchanged.dryRun = false
            write(args.has("json") ? Export.json(unchanged) : tr("All items are already at their original locations."))
            return
        }
        guard review.items.contains(where: { $0.status == "restored" }) else {
            write(args.has("json") ? Export.json(review) : tr("Nothing in this batch can be restored."))
            exit(1)
        }
        if !args.has("yes") {
            guard !args.has("json"), isatty(STDIN_FILENO) != 0 else { throw CLIError("add --yes after reviewing the batch with --dry-run") }
            print(tr("Restore these items? [y/N] "), terminator: ""); fflush(stdout)
            guard let answer = readLine(), ["y", "yes"].contains(answer.lowercased()) else { print(tr("cancelled")); return }
        }
        guard let identity = review.reviewIdentity else { throw CLIError(tr("Restore review is unavailable; review the batch again.")) }
        let result = try TrashBatches.restore(id: selectors[0], home: home, reviewIdentity: identity,
            reviewedDestinations: Set(review.items.filter { $0.status == "restored" }.map(\.destination)))
        let restored = result.items.filter { $0.status == "restored" }
        let already = result.items.filter { $0.status == "alreadyRestored" }
        if args.has("json") { write(Export.json(result)) }
        else {
            lines(result).forEach(write)
            write(style.bold(tr("Restored %1$@ of %2$@ items", String(restored.count), String(result.items.count - already.count))))
            if !already.isEmpty { write(tr("%1$@ items were already at their original locations.", String(already.count))) }
            for issue in result.issues ?? [] { write(style.yellow(tr(issue))) }
        }
        if restored.count + already.count != result.items.count { exit(1) }
    }

    static func restoreStatus(_ status: String) -> String {
        switch status {
        case "conflict": return tr("conflict")
        case "missing": return tr("missing")
        case "alreadyRestored": return tr("already restored")
        case "changed": return tr("changed")
        case "skipped": return tr("skipped")
        default: return tr("failed")
        }
    }

    /// The saved report when it is under 15 minutes old, made with the same age limit, and covers
    /// what `selectors` ask for; the picked items come back without paths that are gone.
    func reusableReport(for selectors: [String]) throws -> (report: ScanReport, picked: [CleanItem])? {
        let configured = try options()
        let needs = selectors.reduce(into: Set<CleanCategory>()) { set, selector in
            let s = selector.lowercased()
            if ["all", "safe"].contains(s) { set.formUnion(CleanCategory.allCases) }
            else if s == "ai" { set.formUnion(CleanCategory.allCases.filter(\.isAI)) }
            else if let c = CleanCategory(rawValue: s) { set.insert(c) }
        }
        guard let r = ScanReportCache.load(maxAge: 15 * 60, matching: { report in
            guard report.olderThanDays == configured.olderThanDays,
                  report.sessionRetentionDays == configured.sessionRetentionDays,
                  report.sessionPolicyVersion == ScanOptions.sessionPolicyVersion,
                  (report.exactSizes ?? false) == configured.exactSizes,
                  report.language == L10n.current.rawValue,
                  needs.isSubset(of: Set(report.categories ?? [])),
                  report.projectRoots == Array(Set(configured.projectRoots)).sorted(),
                  report.discoverProjectRoots == configured.discoverProjectRoots else { return false }
            return selectors.allSatisfy { !report.select([$0]).isEmpty }
        }) else { return nil }
        let picked = r.select(selectors)
        guard !picked.isEmpty else { return nil }
        return (r, picked.map(refreshed))
    }

    /// The item as it is now: paths that are gone are dropped. Sizes stay as scanned — measuring
    /// again would cost what we are avoiding, and removal re-walks each path anyway (it skips
    /// anything changed since the scan and reports removed file estimates and live volume measurements).
    func refreshed(_ item: CleanItem) -> CleanItem {
        var i = item
        let kept = item.paths.filter(FS.exists)
        if let parts = item.parts {
            i.parts = parts.compactMap { p in
                var p = p
                p.paths = p.paths.filter(FS.exists)
                return p.paths.isEmpty ? nil : p
            }
            i.bytes = (i.parts ?? []).reduce(0) { $0 + $1.bytes }
        } else if kept.count < item.paths.count, !item.paths.isEmpty {
            i.bytes = item.bytes * Int64(kept.count) / Int64(item.paths.count)
        }
        i.paths = kept
        return i
    }

    func showLog() {
        let text = (try? String(contentsOf: Cleaner.logURL, encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n").suffix(args.has("all") ? Int.max : 40).map(String.init)
        if args.has("json") {
            struct Log: Encodable { let file: String; let lines: [String] }
            print(Export.json(Log(file: Cleaner.logURL.path, lines: lines)))
        } else { out(lines.isEmpty ? ["no cleanup yet"] : lines) }
    }
}
