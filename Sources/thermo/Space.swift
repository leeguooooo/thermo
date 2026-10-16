import AgentCore
import CleanKit
import Foundation

/// `thermo space [PATH]`: what takes the space in a folder, biggest first (walks the tree once and
/// keeps it, so `thermo space PATH/sub` answers from the same walk).
/// `thermo space large [--older-than DAYS]`: big files, with when they were last opened.
/// `thermo space dupes [PATH…]`: files with identical contents.
/// `thermo space trash PATH… [--yes]`: move picked paths to the Trash.
struct SpaceCommand {
    let app: App
    var style: Style { app.style }
    var args: Args { app.args }

    func run(_ rest: [String]) throws {
        switch rest.first {
        case "archive": try archive(rest.dropFirst().first)
        case "large", "big": try large()
        case "dupes", "duplicates": try dupes(Array(rest.dropFirst()))
        case "trash", "rm": try trash(Array(rest.dropFirst()))
        case "browse": try browse(rest.dropFirst().first)
        default: try browse(rest.first)
        }
    }

    func archive(_ source: String?) throws {
        guard let source, let specification = args.options["to"] else {
            throw CLIError("usage: thermo space archive PATH --to nas:/archive/name.tar [--dry-run] [--remove-local] [--inactive-development] [--yes]")
        }
        let target = try SSHArchiveDestination(specification)
        let removal = args.has("remove-local")
        let inactive = args.has("inactive-development")
        let plan = try VerifiedArchive.plan(source: Self.expand(source), destination: target, removeLocal: removal, allowDevelopment: inactive)
        if args.has("dry-run") { print(args.has("json") ? Export.json(plan) : "\(plan.files) files · \(ByteFormat.string(plan.allocatedBytes)) allocated · \(ByteFormat.string(plan.payloadBytes)) archive payload · \(target.host):\(target.path)"); return }
        if !args.has("yes") {
            guard isatty(STDIN_FILENO) != 0 else { throw CLIError("not a terminal; review with --dry-run, then add --yes") }
            print("Archive \(plan.files) files to \(target.host):\(target.path)\(removal ? ", then remove verified local files" : ", keeping local files")? [y/N] ", terminator: "")
            fflush(stdout)
            guard let answer = readLine(), ["y", "yes"].contains(answer.lowercased()) else { print(tr("cancelled")); return }
        }
        var last = Date.distantPast
        let result = try VerifiedArchive.archive(source: plan.source, destination: target, removeLocal: removal, allowDevelopment: inactive) { bytes in
            if Date().timeIntervalSince(last) >= 1 { last = Date(); progress("Archiving \(ByteFormat.string(bytes))") }
        }
        clearProgress()
        if args.has("json") { print(Export.json(result)) }
        else { print("Verified archive: \(target.host):\(target.path)\nSHA-256: \(result.sha256)\n\(result.diskSpace.summary)") }
    }

    func progress(_ text: String) {
        guard !args.has("json"), isatty(STDERR_FILENO) != 0 else { return }
        FileHandle.standardError.write(Data(("\r\u{1B}[K" + text).utf8))
    }

    func clearProgress() { progress("") }

    static func expand(_ p: String) -> String {
        let e = (p as NSString).expandingTildeInPath
        let abs = e.hasPrefix("/") ? e : FileManager.default.currentDirectoryPath + "/" + e
        return URL(fileURLWithPath: abs).standardizedFileURL.path
    }

    /// The home folder's tree: from the cache when it is fresh (an hour), otherwise walked now.
    func tree(covering path: String) -> SpaceTree {
        let home = NSHomeDirectory()
        let root = path.hasPrefix(home + "/") || path == home ? home : path
        if !args.has("no-cache"), let t = SpaceLens.cached(root: root), Date().timeIntervalSince(t.scanned) < 3600 { return t }
        let t = SpaceLens.scan(root) { p in
            progress(tr("Measuring %1$@ · %2$@ files · %3$@", FS.tilde(p.current), String(p.files), ByteFormat.string(p.bytes)))
        }
        clearProgress()
        SpaceLens.save(t)
        return t
    }

    func browse(_ arg: String?) throws {
        let path = Self.expand(arg ?? "~")
        let t = tree(covering: path)
        guard let f = t.folder(path) else {
            throw CLIError(tr("%1$@ is smaller than 1 MB or was not measured", FS.tilde(path)))
        }
        if args.has("json") { print(Export.json(f)); return }
        var lines = [style.bold(FS.tilde(path) + "  " + f.entry.sizeText)]
        if f.entry.effectiveSizeState != .complete { lines.append(style.yellow(tr("Some locations were not fully measured. Sizes and chart areas show only known data."))) }
        let total = max(1, f.entry.bytes)
        for c in f.children.prefix(args.has("all") ? .max : 30) {
            let share = Double(c.bytes) / Double(total)
            let bar = String(repeating: "█", count: Int(share * 20)) + String(repeating: "·", count: 20 - Int(share * 20))
            lines.append("  " + pad(c.sizeText, 18, right: true) + "  " + style.dim(bar) + "  " + c.name + (c.isDir ? "/" : ""))
        }
        if f.otherBytes > 0 {
            lines.append(style.dim("  " + pad(ByteFormat.string(f.otherBytes), 9, right: true) + "  "
                                   + tr("%1$@ smaller items", String(f.otherCount))))
        }
        lines.append(style.dim(tr("measured %1$@ · thermo space PATH to look inside · --no-cache to measure again",
                                  t.scanned.formatted(date: .abbreviated, time: .shortened))))
        out(lines)
    }

    func large() throws {
        let t = tree(covering: NSHomeDirectory())
        let days = try args.int("older-than")
        var rows: [(LargeFile, Date?)] = t.large.prefix(500).map { ($0, SpaceLens.lastOpened($0.path)) }
        let unknownDates = rows.filter { $0.1 == nil }.count
        if let days {
            let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
            rows = rows.filter { SpaceLens.notOpened(since: cutoff, lastOpened: $0.1) }
        }
        if args.has("json") {
            struct Row: Encodable { let path: String; let bytes: Int64; let modified: Date; let lastOpened: Date? }
            print(Export.json(rows.map { Row(path: $0.0.path, bytes: $0.0.bytes, modified: $0.0.modified, lastOpened: $0.1) }))
            return
        }
        var lines = [style.bold(pad(tr("Size"), 9, right: true) + "  " + pad(tr("Last opened"), 12) + "  " + tr("File"))]
        if days != nil && unknownDates > 0 {
            lines.append(style.dim(tr("%1$@ files have no known last opened date and are excluded from this filter.", String(unknownDates))))
        }
        for (f, opened) in rows.prefix(args.has("all") ? .max : 40) {
            lines.append(pad(ByteFormat.string(f.bytes), 9, right: true) + "  "
                         + pad(opened.map(Self.day) ?? style.dim(tr("Unknown")), 12) + "  " + FS.tilde(f.path))
        }
        let total = rows.reduce(Int64(0)) { $0 + $1.0.bytes }
        lines.append(style.dim(tr("%1$@ files over 100 MB, %2$@ · --older-than DAYS · thermo space trash PATH…",
                                  String(rows.count), ByteFormat.string(total))))
        out(lines)
    }

    func dupes(_ roots: [String]) throws {
        let home = NSHomeDirectory()
        let paths = roots.isEmpty ? Duplicates.defaultRoots(home: home)
            : roots.map(Self.expand)
        let report = Duplicates.scan(in: paths) { p in
            progress(p.total > 0 ? "\(p.stage) \(p.done)/\(p.total)" : "\(p.stage) \(p.done)")
        }
        clearProgress()
        if args.has("json") { print(Export.json(report)); if !report.complete { exit(1) }; return }
        let groups = report.groups
        var lines: [String] = []
        if !report.complete {
            lines.append(style.yellow(tr("Duplicate scan is incomplete. Some locations could not be compared.")))
            for issue in report.issues { lines.append(style.dim(FS.tilde(issue.path) + ": " + issue.reason)) }
            if report.omittedIssueCount > 0 { lines.append(tr("%1$@ additional scan issues were omitted.", String(report.omittedIssueCount))) }
        }
        for g in groups.prefix(args.has("all") ? .max : 25) {
            lines.append(style.bold(ByteFormat.string(g.size)) + style.dim("  ×\(g.paths.count)  " + tr("frees %1$@", AppSize.text(g.reclaimable, state: g.reclaimableState ?? .unavailable))))
            for (i, p) in g.paths.enumerated() { lines.append((i == 0 ? "  = " : "  + ") + FS.tilde(p)) }
        }
        let total = groups.reduce(Int64(0)) { $0 + $1.reclaimable }
        lines.append(style.dim(tr("%1$@ sets of identical files; removing the extra copies (+) frees %2$@", String(groups.count), AppSize.text(total, state: AppSize.combined(groups.map { $0.reclaimableState ?? .unavailable } + (report.complete ? [] : [.incomplete]), bytes: total)))))
        out(lines)
        if !report.complete { exit(1) }
    }

    func trash(_ raw: [String]) throws {
        guard !raw.isEmpty else { throw CLIError("usage: thermo space trash PATH… [--yes]") }
        let paths = raw.map(Self.expand)
        var lines = [style.bold(tr("Move to the Trash:"))]
        var ok: [String] = []
        var sizes: [String: Int64] = [:], identities: [String: String] = [:]
        var incomplete = Set<String>()
        for p in Array(Set(paths)).sorted() {
            if let why = ManualRemoval.refusal(p) { lines.append(style.yellow("  ✗ " + FS.tilde(p) + "  " + why)) }
            else {
                let identity = ManualRemoval.reviewIdentity(p)
                let size = FS.size(p)
                guard let identity, ManualRemoval.reviewIdentity(p) == identity else {
                    lines.append(style.yellow("  ✗ " + FS.tilde(p) + "  " + tr("The selected item changed after review; select it again")))
                    continue
                }
                identities[p] = identity; sizes[p] = size.bytes
                if size.incomplete || size.denied { incomplete.insert(p) }
                ok.append(p); lines.append("  " + AppSize.text(size.bytes, state: AppSize.measured(size, exists: FS.exists(p))) + "  " + FS.tilde(p))
            }
        }
        out(lines)
        guard !ok.isEmpty else { exit(1) }
        if args.has("dry-run") { print(tr("dry run · nothing moved")); return }
        if !args.has("yes") {
            guard isatty(STDIN_FILENO) != 0 else { throw CLIError("not a terminal; add --yes to confirm") }
            print(tr("Move these %1$@ items to the Trash? [y/N] ", String(ok.count)), terminator: "")
            fflush(stdout)
            guard let answer = readLine(), ["y", "yes"].contains(answer.lowercased()) else { print(tr("cancelled")); return }
        }
        let result = ManualRemoval.trash(ok, sizes: sizes, incompletePaths: incomplete, reviewIdentities: identities)
        for line in ManualRemoval.feedback(result) { print(line) }
        if let id = result.trashBatchID { print(style.dim(tr("Put back: thermo clean restore %1$@", id))) }
        if !result.failed.isEmpty { exit(1) }
    }

    static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}
