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
        if args.has("stream") {
            guard !args.has("csv"), !["run", "log"].contains(rest.first ?? "") else {
                throw CLIError("--stream is for read-only scans and cannot be combined with --csv")
            }
        }
        switch rest.first {
        case "run": try clean(Array(rest.dropFirst()))
        case "log": showLog()
        case "overview", "space": overview()
        default: try report(filter: rest)
        }
    }

    /// Where the used space is: the big places on this disk and the biggest folders in each.
    func overview() {
        let stream = args.has("stream") ? ScanStream() : nil
        stream?.start()
        let tty = isatty(STDERR_FILENO) != 0 && !args.has("json") && stream == nil
        let o = SpaceOverview.measure(onProgress: { step in
            stream?.emit(.init(event: "progress", step: step))
            if tty { FileHandle.standardError.write(Data(".".utf8)) }
        }, onEntry: { entry in stream?.emit(.init(event: "entry", entry: entry)) })
        if let stream { stream.emit(.init(event: "finished", overview: o)); o.save(); return }
        o.save()  // the app's Overview opens with these numbers
        if tty { FileHandle.standardError.write("\n".data(using: .utf8)!) }
        if args.has("json") { print(Export.json(o)); return }
        func gb(_ b: Int64) -> String { b >= 1_000_000_000 ? String(format: "%.1f GB", Double(b) / 1e9) : String(format: "%.0f MB", Double(b) / 1e6) }
        var lines = [style.bold("Disk") + style.dim(String(format: " · %@ used of %@ · %@ free", gb(o.used), gb(o.capacity), gb(o.free))
                     + (o.purgeable > 1_000_000_000 ? " (+\(gb(o.purgeable)) purgeable)" : "")), ""]
        for e in o.entries where e.bytes >= 100_000_000 {
            lines.append(pad(gb(e.bytes), 9, right: true) + "  " + style.bold(e.title))
            if let n = e.note { lines.append(pad("", 11) + style.dim(n)) }
            for c in e.children.prefix(args.has("all") ? 20 : 5) where c.bytes >= 100_000_000 {
                lines.append(pad("", 11) + pad(gb(c.bytes), 9, right: true) + "  " + c.title)
            }
        }
        lines.append("")
        lines.append(style.dim(String(format: "measured in %.0f s · what can go: thermo clean", o.duration)))
        out(lines)
    }

    func options() throws -> ScanOptions {
        var o = ScanOptions()
        if let v = args.options["older-than"] {
            guard let d = parseDays(v) else { throw CLIError("--older-than expects days like 30, 2w, 6m or 1y; got '\(v)'") }
            o.olderThanDays = d
        }
        if let roots = args.options["root"] {
            o.discoverProjectRoots = false
            o.projectRoots = roots.split(separator: ",").map { FS.expand(String($0)) }
                .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        }
        return o
    }

    func scan(_ categories: Set<CleanCategory>? = nil) throws -> ScanReport {
        var o = try options()
        if let categories { o.categories = categories }
        let scanner = DiskScanner(options: o)
        let stream = args.has("stream") ? ScanStream() : nil
        stream?.start()
        if let stream {
            scanner.onItems = { stream.emit(.init(event: "items", items: $0)) }
            scanner.onProgress = { stream.emit(.init(event: "progress", step: $0)) }
        }
        let tty = isatty(STDERR_FILENO) != 0 && !args.has("json") && !args.has("csv") && stream == nil
        if tty {
            let lock = NSLock()
            var done = 0
            scanner.onProgress = { step in
                lock.lock(); done += 1; let n = done; lock.unlock()
                FileHandle.standardError.write("\r\u{1B}[2Kscanning… \(n) · \(step.prefix(40))".data(using: .utf8)!)
            }
        }
        let r = scanner.scan()
        stream?.emit(.init(event: "finished", report: r))
        if tty { FileHandle.standardError.write("\r\u{1B}[2K".data(using: .utf8)!) }
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
        if args.has("stream") { return }
        if args.has("json") { print(Export.json(r)); return }
        if args.has("csv") {
            print("id,category,safety,bytes,files,last_used,title,detail,blocked")
            let f = ISO8601DateFormatter()
            for i in r.items {
                print([i.id, i.category.rawValue, i.safety.rawValue, String(i.bytes), String(i.files),
                       i.lastUsed.map(f.string) ?? "", i.title, i.detail, i.blocked ?? ""].map(Export.csvField).joined(separator: ","))
            }
            return
        }
        let showAll = args.has("all") || cats != nil
        var lines = [style.bold("thermo clean") + style.dim(" · ") + style.green(ByteFormat.string(r.totalBytes)) + style.dim(" reclaimable · scanned in \(String(format: "%.1f", r.duration)) s · nothing was deleted")]
        let width = min(terminalWidth(), 140)
        for c in CleanCategory.allCases {
            let items = r.items.filter { $0.category == c }
            guard !items.isEmpty else { continue }
            lines.append("")
            lines.append(pad(style.bold(c.title), 0) + style.dim("  " + ByteFormat.string(r.bytes(in: c))))
            let shown = showAll ? items : Array(items.prefix(6))
            for i in shown { lines += render(i, width: width) }
            if shown.count < items.count {
                let more = items.dropFirst(shown.count)
                lines.append(style.dim("  + \(more.count) more (\(ByteFormat.string(more.reduce(0) { $0 + $1.bytes }))) · thermo clean \(c.rawValue)"))
            }
        }
        if r.items.isEmpty { lines.append(""); lines.append(style.dim("  nothing to clean")) }
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
        out(lines)
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
        if let n = i.note {
            let limit = max(40, width - 22)
            lines.append(indent + style.dim(n.count > limit ? String(n.prefix(limit - 1)) + "…" : n))
        }
        if let h = i.hint { lines.append(indent + style.dim("run: ") + h) }
        if args.has("all"), let parts = i.parts, parts.count > 1 {
            for p in parts {
                lines.append(indent + "  " + pad(ByteFormat.string(p.bytes), 8, right: true) + "  " + style.cyan("#" + p.id)
                             + style.dim("  " + AgeFormat.string(p.lastUsed) + "  ") + String(p.title.prefix(60)))
            }
        }
        return lines
    }

    // MARK: run

    func clean(_ selectors: [String]) throws {
        guard !selectors.isEmpty else {
            throw CLIError("usage: thermo clean run safe|all|ai|CATEGORY|ID… [--older-than 30d] [--trash|--permanent] [--yes]")
        }
        if args.has("trash") && args.has("permanent") { throw CLIError("--trash and --permanent are exclusive") }
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
            r = try scan(needsProjects ? nil : Set(CleanCategory.allCases.filter { $0 != .projects }))
            picked = r.select(selectors)
        }
        guard !picked.isEmpty else {
            throw CLIError("nothing matches \(selectors.joined(separator: " ")); see thermo clean")
        }
        let todo = picked.filter(\.cleanable)
        let skipped = picked.filter { !$0.cleanable }
        let total = todo.reduce(Int64(0)) { $0 + $1.bytes }

        var plan = [style.bold("About to clean \(ByteFormat.string(total)) in \(todo.count) item\(todo.count == 1 ? "" : "s"):")]
        for i in todo {
            let how = mode.trashes(i.safety) ? style.yellow("trash ") : style.red("delete")
            plan.append("  " + pad(ByteFormat.string(i.bytes), 8, right: true) + "  " + how + "  " + i.title + style.dim("  \(i.paths.count) path\(i.paths.count == 1 ? "" : "s")"))
        }
        for i in skipped {
            plan.append(style.dim("  skipped  \(i.title): \(i.blocked ?? (i.hint.map { "run \($0)" } ?? "nothing to remove"))"))
        }
        if args.has("json") == false { out(plan) }
        guard !todo.isEmpty else { return }

        if !args.has("yes") {
            guard isatty(STDIN_FILENO) != 0 else { throw CLIError("not a terminal; add --yes to confirm") }
            print("Proceed? [y/N] ", terminator: "")
            fflush(stdout)
            guard let answer = readLine(), ["y", "yes"].contains(answer.lowercased()) else { print("cancelled"); return }
        }

        var results: [CleanResult] = []
        for i in todo {
            let res = Cleaner.clean(i, mode: mode, scannedAt: r.started)
            results.append(res)
            if !args.has("json") {
                let ok = res.failed.isEmpty
                print("  " + (ok ? style.green("✓") : style.yellow("!")) + " " + pad(ByteFormat.string(res.bytes), 8, right: true) + "  " + i.title
                      + (res.trashed ? style.dim("  (Trash)") : ""))
                for (p, why) in res.failed.sorted(by: { $0.key < $1.key }).prefix(5) { print(style.dim("      \(FS.tilde(p)): \(why)")) }
            }
        }
        if args.has("json") { print(Export.json(results)); return }
        let freed = results.filter { !$0.trashed }.reduce(Int64(0)) { $0 + $1.bytes }
        let trashed = results.filter(\.trashed).reduce(Int64(0)) { $0 + $1.bytes }
        var summary = "freed \(ByteFormat.string(freed))"
        if trashed > 0 { summary += ", moved \(ByteFormat.string(trashed)) to the Trash (empty it to reclaim the space)" }
        print(style.bold(summary) + style.dim(" · log: \(FS.tilde(Cleaner.logURL.path))"))
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
    /// anything changed since the scan and reports what was really freed).
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
        guard let text = try? String(contentsOf: Cleaner.logURL, encoding: .utf8) else { print(style.dim("no cleanup yet")); return }
        out(text.split(separator: "\n").suffix(args.has("all") ? Int.max : 40).map(String.init))
    }
}
