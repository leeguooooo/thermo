import AgentCore
import CleanKit
import Foundation

/// `thermo apps`: installed apps with their size and the files they keep in the home folder.
/// `thermo apps uninstall NAME [--dry-run] [--yes]`: the app and its files go to the Trash.
/// `thermo apps leftovers [remove ID…|all]`: data left behind by apps that are gone.
struct AppsCommand {
    let app: App
    var style: Style { app.style }
    var args: Args { app.args }

    func run(_ rest: [String]) throws {
        switch rest.first {
        case "uninstall", "remove", "rm": try uninstall(Array(rest.dropFirst()))
        case "leftovers", "orphans": try leftovers(Array(rest.dropFirst()))
        case nil, "list", "ls": list()
        default: throw CLIError("usage: thermo apps [uninstall NAME [--dry-run] [--yes] | leftovers [remove ID…|all]]")
        }
    }

    func progress(_ text: String) {
        guard !args.has("json"), isatty(STDERR_FILENO) != 0 else { return }
        FileHandle.standardError.write(Data(("\r\u{1B}[K" + text).utf8))
    }

    func clearProgress() {
        guard !args.has("json"), isatty(STDERR_FILENO) != 0 else { return }
        FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))
    }

    func list() {
        progress(tr("Measuring apps…"))
        let apps = AppUninstaller.measure(AppUninstaller.installed()).sorted { $0.totalBytes > $1.totalBytes }
        clearProgress()
        if args.has("json") { print(Export.json(apps)); return }
        var lines = [style.bold(pad(tr("App"), 34) + pad(tr("App size"), 10, right: true) + pad(tr("Its files"), 11, right: true))]
        for a in apps {
            var line = pad(String(a.name.prefix(33)), 34) + pad(ByteFormat.string(a.bytes), 10, right: true)
                + pad(a.leftovers.isEmpty ? "–" : ByteFormat.string(a.leftoverBytes), 11, right: true)
            if let why = a.protected { line += style.dim("  " + why) }
            else if let cask = a.cask { line += style.dim("  brew: " + cask) }
            lines.append(line)
        }
        let total = apps.reduce(Int64(0)) { $0 + $1.totalBytes }
        lines.append(style.dim(tr("%1$@ apps, %2$@ with their files · thermo apps uninstall NAME", String(apps.count), ByteFormat.string(total))))
        out(lines)
    }

    func uninstall(_ names: [String]) throws {
        guard let query = names.first, names.count == 1 else { throw CLIError("usage: thermo apps uninstall NAME [--dry-run] [--yes] [--with-data]") }
        let installed = AppUninstaller.installed()
        let found = AppUninstaller.find(query, in: installed)
        guard !found.isEmpty else { throw CLIError(tr("no installed app matches '%1$@' (see thermo apps)", query)) }
        guard found.count == 1, let target = found.first else {
            throw CLIError(tr("'%1$@' matches several apps; use the full name or bundle ID:", query) + "\n"
                           + found.map { "  \($0.name)  \($0.bundleID ?? "")  \($0.path)" }.joined(separator: "\n"))
        }
        progress(tr("Looking for %1$@'s files…", target.name))
        let plan = AppUninstaller.plan(target, installed: installed, includePersonal: args.has("with-data"))
        clearProgress()

        if args.has("json") && (args.has("dry-run") || plan.blocked != nil) {
            print(Export.json(plan))
            if plan.blocked != nil { exit(1) }
            return
        }
        var lines = [style.bold(tr("Uninstall %1$@ (%2$@): move %3$@ to the Trash", target.name + (target.version.map { " " + $0 } ?? ""),
                                   target.bundleID ?? tr("no bundle ID"), ByteFormat.string(plan.bytes)))]
        lines.append("  " + pad(ByteFormat.string(plan.app.bytes), 9, right: true) + "  " + FS.tilde(plan.app.path))
        for l in plan.app.leftovers where plan.paths.contains(l.path) {
            lines.append("  " + pad(ByteFormat.string(l.bytes), 9, right: true) + "  " + FS.tilde(l.path))
        }
        if let kept = plan.kept, !kept.isEmpty {
            lines.append(style.dim(tr("Kept, your data (profiles, chat history, mail); add --with-data to move it too:")))
            for l in kept { lines.append(style.dim("  " + pad(ByteFormat.string(l.bytes), 9, right: true) + "  " + FS.tilde(l.path))) }
        }
        if let cask = plan.app.cask {
            lines.append(style.dim(tr("Homebrew installed it: run brew uninstall --cask %1$@ afterwards so Homebrew forgets it.", cask)))
        }
        if !plan.receipts.isEmpty {
            lines.append(style.dim(tr("Installed by a package (%1$@); files it put outside your home folder stay.", plan.receipts.joined(separator: ", "))))
        }
        if let why = plan.blocked {
            lines.append(style.yellow(tr("Not uninstalled: %1$@", why)))
            out(lines)
            exit(1)
        }
        if args.has("dry-run") {
            out(lines + [tr("dry run · nothing moved")])
            return
        }
        if !args.has("json") { out(lines) }
        if !args.has("yes") {
            guard isatty(STDIN_FILENO) != 0 else { throw CLIError("not a terminal; add --yes to confirm") }
            print(tr("Move these %1$@ items to the Trash? [y/N] ", String(plan.paths.count)), terminator: "")
            fflush(stdout)
            guard let answer = readLine(), ["y", "yes"].contains(answer.lowercased()) else { print(tr("cancelled")); return }
        }
        let result = AppUninstaller.uninstall(plan)
        report([result])
        if !result.failed.isEmpty { exit(1) }
    }

    func leftovers(_ rest: [String]) throws {
        let removing = rest.first == "remove" || rest.first == "clean"
        progress(tr("Looking for data of apps that are gone…"))
        let installed = AppUninstaller.installed()
        let known = AppUninstaller.knownBundleIDs(installed: installed, processes: ProcessTable.current(.init(cpu: false)))
        let found = AppUninstaller.orphans(known: known, minimumBytes: args.has("all") || removing ? 0 : 1 << 20)
        clearProgress()

        if !removing {
            if args.has("json") { print(Export.json(found)); return }
            guard !found.isEmpty else { print(tr("No data left behind by deleted apps (untouched for 30 days and unknown to Spotlight).")); return }
            var lines: [String] = []
            for o in found {
                lines.append(pad(ByteFormat.string(o.bytes), 9, right: true) + "  " + style.bold(o.bundleID)
                             + style.dim("  " + (o.lastUsed.map { tr("last changed %1$@", Self.day($0)) } ?? "")))
                for i in o.items { lines.append(style.dim("           " + FS.tilde(i.path))) }
            }
            let total = found.reduce(Int64(0)) { $0 + $1.bytes }
            lines.append(style.dim(tr("%1$@ in %2$@ apps that are gone · thermo apps leftovers remove ID…|all", ByteFormat.string(total), String(found.count))))
            out(lines)
            return
        }

        let ids = Array(rest.dropFirst())
        guard !ids.isEmpty else { throw CLIError("usage: thermo apps leftovers remove ID…|all [--dry-run] [--yes]") }
        let picked = ids == ["all"] ? found : found.filter { o in ids.contains { $0.caseInsensitiveCompare(o.bundleID) == .orderedSame } }
        let missing = ids == ["all"] ? [] : ids.filter { id in !found.contains { $0.bundleID.caseInsensitiveCompare(id) == .orderedSame } }
        if !missing.isEmpty { throw CLIError(tr("not left behind by a deleted app: %1$@", missing.joined(separator: ", "))) }
        guard !picked.isEmpty else { print(tr("Nothing to remove.")); return }
        let total = picked.reduce(Int64(0)) { $0 + $1.bytes }
        var lines = [style.bold(tr("Move %1$@ left behind by %2$@ deleted apps to the Trash:", ByteFormat.string(total), String(picked.count)))]
        for o in picked {
            for i in o.items { lines.append("  " + pad(ByteFormat.string(i.bytes), 9, right: true) + "  " + FS.tilde(i.path)) }
        }
        if args.has("dry-run") {
            if args.has("json") { print(Export.json(picked)) } else { out(lines + [tr("dry run · nothing moved")]) }
            return
        }
        if !args.has("json") { out(lines) }
        if !args.has("yes") {
            guard isatty(STDIN_FILENO) != 0 else { throw CLIError("not a terminal; add --yes to confirm") }
            print(tr("Move these %1$@ items to the Trash? [y/N] ", String(picked.reduce(0) { $0 + $1.items.count })), terminator: "")
            fflush(stdout)
            guard let answer = readLine(), ["y", "yes"].contains(answer.lowercased()) else { print(tr("cancelled")); return }
        }
        let results = AppUninstaller.removeOrphans(picked, installed: installed)
        report(results)
        if results.contains(where: { !$0.failed.isEmpty }) { exit(1) }
    }

    func report(_ results: [CleanResult]) {
        if args.has("json") { print(Export.json(results)); return }
        for r in results {
            for p in r.removed { print("  " + style.green("✓") + " " + FS.tilde(p)) }
            for (p, why) in r.failed.sorted(by: { $0.key < $1.key }) { print("  " + style.yellow("!") + " " + FS.tilde(p) + style.dim(": " + why)) }
        }
        let bytes = results.reduce(Int64(0)) { $0 + $1.bytes }
        print(style.bold(tr("Moved %1$@ to the Trash (empty it to get the space back)", ByteFormat.string(bytes)))
              + style.dim(" · log: \(FS.tilde(Cleaner.logURL.path))"))
        for id in results.compactMap(\.trashBatchID) { print(style.dim(tr("Put back: thermo clean restore %1$@", id))) }
    }

    static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}
