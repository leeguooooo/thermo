import CleanKit
import Foundation

/// `thermo clean`: scan (read-only) and `thermo clean run`: remove selected items.
struct CleanCommand {
    let app: App
    var style: Style { app.style }
    var args: Args { app.args }

    func run(_ rest: [String]) throws {
        switch rest.first {
        case "run": try clean(Array(rest.dropFirst()))
        case "log": showLog()
        default: try report(filter: rest)
        }
    }

    func options() throws -> ScanOptions {
        var o = ScanOptions()
        if let v = args.options["older-than"] {
            guard let d = parseDays(v) else { throw CLIError("--older-than expects days like 30, 2w, 6m or 1y; got '\(v)'") }
            o.olderThanDays = d
        }
        if let roots = args.options["root"] {
            o.projectRoots = roots.split(separator: ",").map { FS.expand(String($0)) }
                .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        }
        return o
    }

    func scan(_ categories: Set<CleanCategory>? = nil) throws -> ScanReport {
        var o = try options()
        if let categories { o.categories = categories }
        let scanner = DiskScanner(options: o)
        let tty = isatty(STDERR_FILENO) != 0 && !args.has("json") && !args.has("csv")
        if tty {
            let lock = NSLock()
            var done = 0
            scanner.onProgress = { step in
                lock.lock(); done += 1; let n = done; lock.unlock()
                FileHandle.standardError.write("\r\u{1B}[2Kscanning… \(n) · \(step.prefix(40))".data(using: .utf8)!)
            }
        }
        let r = scanner.scan()
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
        let r = try scan(needsProjects ? nil : Set(CleanCategory.allCases.filter { $0 != .projects }))
        let picked = r.select(selectors)
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

    func showLog() {
        guard let text = try? String(contentsOf: Cleaner.logURL, encoding: .utf8) else { print(style.dim("no cleanup yet")); return }
        out(text.split(separator: "\n").suffix(args.has("all") ? Int.max : 40).map(String.init))
    }
}
