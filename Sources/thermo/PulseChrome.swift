import CleanKit
import Foundation

/// `thermo pulse chrome [--watch 60] [--app NAME] [--json]`: which browser page is the problem —
/// leaking pages, the biggest ones, duplicate tabs, workers per site, hidden automation pages.
/// `thermo pulse chrome close URL [--title T] --yes`: close one tab showing URL.
extension PulseCommand {
    func chrome(_ rest: [String]) throws {
        let style = app.style
        let browser = app.args.options["app"] ?? "Google Chrome"
        if rest.first == "close" { try closeTab(Array(rest.dropFirst()), browser: browser); return }
        var watch: TimeInterval?
        if let w = app.args.options["watch"] {
            guard let v = TimeInterval(w), v >= 10, v <= 600 else { throw CLIError("--watch expects seconds between 10 and 600; got '\(w)'") }
            watch = v
        }
        let rounds = watch == nil ? "1" : "2"
        let hog = MachinePulse.sample().hogs.first { $0.name == browser }
        let gpu = hog?.parts?.first { $0.role == "GPU" }?.memoryKB
        let json = app.args.has("json")
        let structured = json || app.args.has("csv")
        let interactive = !structured && isatty(STDERR_FILENO) != 0

        let seconds = watch
        // Measuring attaches to every page (Chrome shows "is being debugged" for a moment): only on request.
        let measure = watch != nil || app.args.has("measure")
        if measure && !structured && ChromeInspector.endpoint(app: browser) != nil {
            FileHandle.standardError.write(Data((ChromeInspector.debuggingBarNote + "\n").utf8))
        }
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        Task {
            box.value = await ChromeInspector.diagnose(app: browser, measure: measure, watch: seconds, appMemoryKB: hog?.memoryKB, gpuKB: gpu) { phase in
                guard interactive else { return }
                let line: String
                switch phase {
                case .measuring(let round, let d, let t):
                    line = tr("Measuring pages (%1$@/%2$@): %3$@ of %4$@", String(round), rounds, String(d), String(t))
                case .waiting(let left): line = tr("Waiting %1$@ s to see which pages grow…", String(left))
                case .listingTabs: line = tr("Listing tabs…")
                }
                FileHandle.standardError.write(Data(("\r\u{1B}[K" + line).utf8))
            }
            done.signal()
        }
        done.wait()
        if interactive { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }
        guard let d = box.value else { return }
        if structured {
            print(json ? Export.diagnosticJSON(d) : Export.pulseCSV(d))
            if d.mode == .unavailable { exit(1) }
            return
        }

        var lines: [String] = []
        func mb(_ v: Double) -> String { MemoryFormat.string(mebibytes: v) }
        func short(_ p: String, _ n: Int = 60) -> String { p.count > n ? String(p.prefix(n - 1)) + "…" : p }
        func page(_ title: String, _ url: String) -> String {
            (title.isEmpty ? short(url) : short(title, 40) + style.dim("  " + ChromeInspector.site(url)))
        }
        switch d.mode {
        case .devtools:
            guard let r = d.report else { break }
            lines.append(style.bold(tr("%1$@: %2$@ pages, %3$@ workers", browser, String(r.pages.count), String(r.workerCount)))
                         + style.dim("  " + tr("JavaScript %1$@", mb(r.pagesHeapMB + r.workersHeapMB))))
            if let notice = Self.browserComparisonNotice(r) { lines.append(style.yellow("  " + notice)) }
            if let s = r.seconds, (r.comparedPages ?? r.pages.count) > 0 {
                lines.append("")
                if r.leaking.isEmpty {
                    lines.append("  " + style.green("✓") + " " + tr("No notable growth in %1$@ comparable pages over %2$@ s.", String(r.comparedPages ?? r.pages.count), String(Int(s.rounded()))))
                } else {
                    lines.append(style.bold(tr("Growing")) + style.dim("  " + tr("(in %1$@ s)", String(Int(s.rounded())))))
                    for p in r.leaking {
                        let g = p.growth!
                        lines.append("  " + style.red("!") + " " + page(p.title, p.url))
                        lines.append(style.dim(String(format: "      %@ · %+.1f MiB · %+d %@ · %+d %@", mb(p.heapMB), g.heapMB,
                                                      g.listeners, tr("listeners"), g.nodes, tr("nodes"))))
                        if let a = p.advice { lines.append("      " + style.yellow(a)) }
                    }
                }
            } else if r.seconds == nil && r.invalidTimestamp != true {
                lines.append(style.dim("  " + tr("One sample only; add --watch 60 to see which pages grow.")))
            }
            if !r.largest.isEmpty {
                lines.append("")
                lines.append(style.bold(tr("Largest")))
                for p in r.largest {
                    lines.append("  " + pad(mb(p.heapMB), 7, right: true) + "  " + page(p.title, p.url)
                                 + style.dim("  " + tr("%1$@ nodes", String(p.nodes))))
                }
            }
            if !r.workers.isEmpty {
                lines.append("")
                lines.append(style.bold(tr("Workers")))
                for w in r.workers.prefix(5) {
                    lines.append("  " + tr("%1$@ runs %2$@ workers", w.site, String(w.count))
                                 + (w.heapMB >= 1 ? style.dim("  " + mb(w.heapMB)) : ""))
                }
            }
        case .tabs:
            let tabs = d.tabs ?? []
            let windows = Dictionary(grouping: tabs, by: \.window)
            guard !tabs.isEmpty else { print(tr("%1$@ is not running.", browser)); return }
            lines.append(style.bold(tr("%1$@: %2$@ tabs in %3$@ windows", browser, String(tabs.count), String(windows.count))))
            if d.hint == nil && ChromeInspector.endpoint(app: browser) != nil && !measure {
                lines.append(style.dim("  " + tr("Add --watch 60 to measure memory per page and see which pages grow.")))
            }
            // Only worth a line when some window is crowded.
            if windows.count > 1, windows.values.contains(where: { $0.count > 5 }) {
                let counts = windows.values.map(\.count).sorted(by: >).map(String.init).joined(separator: " · ")
                lines.append(style.dim("  " + tr("tabs per window: %1$@", counts)))
            }
        case .unavailable:
            lines.append(style.yellow("!") + " " + tr("Could not look inside %1$@.", browser))
        }
        if !d.duplicates.isEmpty {
            lines.append("")
            lines.append(style.bold(tr("Open more than once")))
            for x in d.duplicates.prefix(8) { lines.append("  ×\(x.count)  " + page(x.title, x.url)) }
        }
        if let h = d.hiddenText { lines.append(""); lines.append(style.yellow("!") + " " + h) }
        if let g = d.gap { lines.append(""); lines.append(style.dim(g)) }
        if let h = d.hint { lines.append(""); lines.append(style.dim(h)) }
        print(lines.joined(separator: "\n"))
        if d.mode == .unavailable { exit(1) }
    }

    static func browserComparisonNotice(_ report: ChromeInspector.Report) -> String? {
        if report.invalidTimestamp == true { return tr("Browser measurement times are invalid. Growth comparisons are unavailable; check again.") }
        if let skipped = report.comparisonSkipped, skipped > 0 {
            return tr("%1$@ pages had no comparable earlier sample; their growth was not evaluated.", String(skipped))
        }
        return nil
    }

    final class Box: @unchecked Sendable { var value: ChromeInspector.Diagnosis? }

    func closeTab(_ rest: [String], browser: String) throws {
        guard let url = rest.first else { throw CLIError("usage: thermo pulse chrome close URL [--title TITLE] [--yes]") }
        let title = app.args.options["title"]
        let matches = (ChromeInspector.tabs(app: browser) ?? []).filter { $0.url == url }
        guard !matches.isEmpty else { throw CLIError("no \(browser) tab shows \(url)") }
        print(tr("Close the %1$@ tab %2$@?", browser, title ?? matches.last!.title) + (matches.count > 1 ? " " + tr("(one of %1$@ with this address)", String(matches.count)) : ""))
        guard try app.args.has("yes") || confirm() else { print(tr("Nothing closed.")); return }
        guard ChromeInspector.close(url: url, title: title, app: browser) else { throw CLIError("\(browser) did not close the tab") }
        print(app.style.green("✓") + " " + tr("closed"))
    }
}
