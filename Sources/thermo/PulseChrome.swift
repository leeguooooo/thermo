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
        let interactive = !json && isatty(STDERR_FILENO) != 0

        let seconds = watch
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        Task {
            box.value = await ChromeInspector.diagnose(app: browser, watch: seconds, appMemoryKB: hog?.memoryKB, gpuKB: gpu) { phase in
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
        if json { print(Export.json(d)); return }

        var lines: [String] = []
        func mb(_ v: Double) -> String { String(format: "%.0f MB", v) }
        func short(_ p: String, _ n: Int = 60) -> String { p.count > n ? String(p.prefix(n - 1)) + "…" : p }
        func page(_ title: String, _ url: String) -> String {
            (title.isEmpty ? short(url) : short(title, 40) + style.dim("  " + ChromeInspector.site(url)))
        }
        switch d.mode {
        case .devtools:
            guard let r = d.report else { break }
            lines.append(style.bold(tr("%1$@: %2$@ pages, %3$@ workers", browser, String(r.pages.count), String(r.workerCount)))
                         + style.dim("  " + tr("JavaScript %1$@", mb(r.pagesHeapMB + r.workersHeapMB))))
            if let s = r.seconds {
                lines.append("")
                if r.leaking.isEmpty {
                    lines.append("  " + style.green("✓") + " " + tr("no page grew in %1$@ s", String(Int(s.rounded()))))
                } else {
                    lines.append(style.bold(tr("Growing")) + style.dim("  " + tr("(in %1$@ s)", String(Int(s.rounded())))))
                    for p in r.leaking {
                        let g = p.growth!
                        lines.append("  " + style.red("!") + " " + page(p.title, p.url))
                        lines.append(style.dim(String(format: "      %@ · %+.1f MB · %+d %@ · %+d %@", mb(p.heapMB), g.heapMB,
                                                      g.listeners, tr("listeners"), g.nodes, tr("nodes"))))
                        if let a = p.advice { lines.append("      " + style.yellow(a)) }
                    }
                }
            } else {
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
            if windows.count > 1 { lines.append(style.dim("  " + windows.values.map { String($0.count) }.sorted { Int($0)! > Int($1)! }.joined(separator: " · "))) }
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
