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
        case "startup": try startup(Array(rest.dropFirst()))
        case "updates": try updates(Array(rest.dropFirst()))
        case nil, "list", "ls": list()
        default: throw CLIError("usage: thermo apps [uninstall NAME | leftovers | startup [enable|disable LABEL]]")
        }
    }

    func updates(_ rest: [String]) throws {
        if ["sources", "check", "install", "recovery"].contains(rest.first ?? "") { try nativeUpdates(rest); return }
        let report = AppUpdates.scan(refreshCatalog: args.has("refresh-catalog"))
        if rest.isEmpty || rest == ["list"] {
            if args.has("json") { print(Export.json(report)); return }
            out([tr("Homebrew apps only. App Store and other app updaters are managed separately.")]
                + report.items.map { "\($0.token)  \($0.installedVersions.joined(separator: ", ")) → \($0.targetVersion)" + ($0.blocked.map { " · " + tr($0) } ?? "") }
                + report.skipped.keys.sorted().map { $0 + ": " + tr(report.skipped[$0] ?? "") }
                + report.issues.map { tr($0) })
            return
        }
        guard rest.count == 2, rest[0] == "apply", let item = report.items.first(where: { $0.token == rest[1] }) else {
            throw CLIError("usage: thermo apps updates [list | apply TOKEN] [--refresh-catalog] [--dry-run] [--yes]")
        }
        if args.has("dry-run") {
            if args.has("json") { print(Export.json(item)) }
            else { out([item.name + ": " + item.installedVersions.joined(separator: ", ") + " → " + item.targetVersion] + item.appPaths + (item.blocked.map { [tr($0)] } ?? [])) }
            return
        }
        if let why = item.blocked { throw CLIError(tr(why)) }
        if !args.has("yes") {
            guard isatty(STDIN_FILENO) != 0 else { throw CLIError("not a terminal; add --yes to confirm") }
            out([item.name + ": " + item.installedVersions.joined(separator: ", ") + " → " + item.targetVersion] + item.appPaths
                + [tr("Homebrew runs the installation steps and may update bundled tools. Thermo cannot automatically roll this update back. Quit the app first.")])
            print(tr("Install this update? [y/N] "), terminator: ""); fflush(stdout)
            guard let answer = readLine(), ["y", "yes"].contains(answer.lowercased()) else { return }
        }
        let result = AppUpdates.install(item)
        if args.has("json") { print(Export.json(result)) } else { out([tr(result.message)]) }
        if result.outcome != "succeeded" { throw CLIError(tr("The update was not verified")) }
    }

    final class FeedResultBox: @unchecked Sendable { var value: NativeUpdateCheck? }
    final class InstallResultBox: @unchecked Sendable { var value: NativeInstallResult? }

    func approveNative(_ lines: [String]) throws -> Bool {
        if args.has("yes") { return true }
        guard !args.has("json"), isatty(STDIN_FILENO) != 0 else { throw CLIError("Review the plan, then add --yes to execute.") }
        out(lines); print(tr("Continue? [y/N] "), terminator: ""); fflush(stdout)
        return readLine().map { ["y", "yes"].contains($0.lowercased()) } ?? false
    }

    func nativeUpdates(_ rest: [String]) throws {
        if rest.first == "recovery" {
            let report = NativeUpdateTransaction.recovery(), records = report.records
            if rest.count == 1 {
                if args.has("json") { print(Export.json(report)) }
                else { out(records.map { $0.id + " · " + $0.target + " · " + $0.previousVersion + " → " + $0.installedVersion + " · " + $0.phase } + report.issues.map { tr($0) }) }
                return
            }
            guard rest.count == 3, rest[1] == "restore", let record = records.first(where: { $0.id == rest[2] }) else {
                throw CLIError("usage: thermo apps updates recovery [restore ID] [--dry-run] [--yes]")
            }
            if args.has("dry-run") { if args.has("json") { print(Export.json(record)) } else { out([record.target, record.backup]) }; return }
            guard try approveNative([record.target, record.installedVersion + " → " + record.previousVersion,
                                     tr("Recovery refuses changed applications and preserves both versions.")]) else { return }
            let result = NativeUpdateTransaction.restore(record.id)
            if args.has("json") { print(Export.json(result)) } else { out([tr(result.message)]) }
            if result.outcome != "succeeded" { throw CLIError(tr(result.message)) }
            return
        }
        let sources = NativeAppUpdates.sources()
        if rest == ["sources"] {
            if args.has("json") { print(Export.json(sources)) }
            else { out(sources.map { $0.app.name + " · " + $0.kind + ($0.feedHost.map { " · " + $0 } ?? "") + ($0.blocked.map { " · " + tr($0) } ?? "") }) }
            return
        }
        guard rest.count == 2, ["check", "install"].contains(rest[0]) else { throw CLIError("usage: thermo apps updates sources | check NAME | install NAME [--dry-run] [--json]") }
        let query = rest[1]
        let matches = sources.filter {
            $0.app.path == query || $0.app.bundleID?.caseInsensitiveCompare(query) == .orderedSame ||
            $0.app.name.caseInsensitiveCompare(query) == .orderedSame || ($0.app.name + ".app").caseInsensitiveCompare(query) == .orderedSame
        }
        guard matches.count == 1, let source = matches.first else { throw CLIError("Choose one exact app name, bundle ID or path from thermo apps updates sources") }
        if args.has("dry-run") {
            if args.has("json") { print(Export.json(source)) }
            else { out([source.app.name, source.kind, source.feedHost ?? tr("No app-declared update feed")]) }
            return
        }
        let box = FeedResultBox(), done = DispatchSemaphore(value: 0)
        let task = Task.detached {
            box.value = await NativeAppUpdates.check(source)
            done.signal()
        }
        guard done.wait(timeout: .now() + 35) == .success, let result = box.value else {
            task.cancel(); throw CLIError(tr("Update check timed out; use the app's own updater"))
        }
        if rest[0] == "install" {
            if let why = NativeUpdateTransaction.installationRefusal(result) { throw CLIError(tr(why)) }
            guard try approveNative([source.app.path, (source.app.version ?? "") + " → " + (result.release?.version ?? ""),
                                     tr("The old app is preserved for recovery. Quit the app first.")]) else { return }
            let installed = InstallResultBox(), finished = DispatchSemaphore(value: 0)
            Task.detached { installed.value = await NativeUpdateTransaction.installAvailable(result); finished.signal() }
            finished.wait()
            guard let outcome = installed.value else { throw CLIError(tr("The native update was not installed")) }
            if args.has("json") { print(Export.json(outcome)) } else { out([tr(outcome.message)]) }
            if outcome.outcome != "succeeded" { throw CLIError(tr(outcome.message)) }
        } else if args.has("json") { print(Export.json(result)) }
        else { out([source.app.name, tr(result.message)] + (result.release.map { [$0.version + " (" + $0.build + ")"] } ?? []) + result.skipped.map { tr($0) }) }
        if ["failed", "changed", "cancelled"].contains(result.status) { throw CLIError(tr(result.message)) }
    }

    func startup(_ rest: [String]) throws {
        let report = StartupItems.scan()
        guard let action = rest.first, action != "list" else {
            guard rest.count <= 1 else { throw CLIError("usage: thermo apps startup [list]") }
            if args.has("json") { print(Export.json(report)); return }
            out(report.items.map { "\($0.enabled.map { $0 ? "on " : "off" } ?? "?  ")  \($0.label)  \($0.path)" + ($0.blocked.map { " · " + tr($0) } ?? "") }
                + report.issues.map { tr($0) })
            return
        }
        guard ["enable", "disable"].contains(action), rest.count == 2,
              let item = report.items.first(where: { $0.label == rest[1] }) else {
            throw CLIError("usage: thermo apps startup [list | enable LABEL | disable LABEL] [--dry-run] [--yes]")
        }
        guard item.blocked == nil, item.enabled != nil else { throw CLIError(tr(item.blocked ?? "Could not read startup state; refresh before changing it")) }
        if args.has("dry-run") {
            if args.has("json") { print(Export.json(["action": action, "label": item.label, "path": item.path])) }
            else { out([action + " " + item.label, item.path, tr("Changes background startup eligibility; does not stop or start a running program.")]) }
            return
        }
        if !args.has("yes") {
            guard isatty(STDIN_FILENO) != 0 else { throw CLIError("not a terminal; add --yes to confirm") }
            print(action + " " + item.label + "? [y/N] ", terminator: ""); fflush(stdout)
            guard let answer = readLine(), ["y", "yes"].contains(answer.lowercased()) else { return }
        }
        let changed = try StartupItems.setEnabled(action == "enable", item: item)
        if args.has("json") { print(Export.json(changed)) }
        else { out([tr("Startup state verified"), changed.label + ": " + (changed.enabled == true ? "on" : "off")]) }
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
        if let saved = plan.whitelisted {
            lines.append(style.dim(tr("Kept, whitelisted:")))
            for p in saved { lines.append(style.dim("  " + FS.tilde(p))) }
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
            for p in r.whitelisted ?? [] { print("  " + style.dim("- " + FS.tilde(p) + ": " + Whitelist.reason)) }
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
