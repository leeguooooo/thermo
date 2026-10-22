import AgentCore
import Foundation
import SearchCore

struct SearchCommand {
    let app: App
    struct Status: Encodable {
        let schemaVersion = 1
        let roots: [SearchRoot]
        let preferences: SearchPreferences
        let complete: Bool
        let issues: [String]
    }
    func run(_ arguments: [String]) throws {
        let sub = arguments.first ?? "query"
        if ["open", "settings", "use-command-space", "give-back-command-space"].contains(sub) { try AppControlCommand(app: app).run(command: "search", rest: arguments); return }
        let store = try SearchStore()
        if sub == "status" {
            guard arguments.count == 1 else { throw CLIError("search status takes no arguments") }
            let status = try store.query("", limit: 1)
            let report = Status(roots: status.roots, preferences: try store.preferences(), complete: status.complete, issues: status.issues)
            if app.args.has("json") { print(Export.json(report)) }
            else {
                print(report.roots.isEmpty ? "Applications only. Add folders in thermo search settings, or run thermo search index --root DIR." : report.roots.map { "\($0.path)  \($0.count) items  \($0.issue ?? ($0.indexedAt > 0 ? "indexed" : "waiting"))" }.joined(separator: "\n"))
            }
            if !report.complete { throw CLIError("Search coverage is incomplete; inspect search status --json.", exitCode: 3) }
            return
        }
        if sub == "index" {
            guard arguments.count == 1 else { throw CLIError("search index takes no positional arguments; use --root DIR") }
            var prefs = try store.preferences()
            if let root = app.args.options["root"] {
                let path = SearchPaths.canonical(URL(fileURLWithPath: root).standardizedFileURL.path)
                var directory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else { throw CLIError("--root must be an existing folder") }
                if !prefs.roots.contains(path) { prefs.roots.append(path); try store.savePreferences(prefs) }
            }
            let apps = ApplicationCatalog.scan()
            try store.replaceApplications(apps.items, complete: apps.complete)
            let cancellation = SearchCancellation()
            for root in prefs.roots {
                let generation = UUID().uuidString
                let report = try SearchFileScanner.scan(root: URL(fileURLWithPath: root), preferences: prefs, cancellation: cancellation, excludingPaths: [store.directory.path]) {
                    try store.upsert($0, root: root, generation: generation)
                }
                try store.finishScan(root: root, generation: generation, complete: report.complete)
                try store.markRoot(root, count: report.count, issue: report.issues.first, available: report.available, completed: report.complete)
            }
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("dev.thermo.search.configurationChanged"), object: nil, userInfo: nil, deliverImmediately: true)
            let roots = try store.rootsReport()
            let complete = apps.complete && roots.allSatisfy { $0.available && $0.issue == nil && $0.indexedAt > 0 }
            if app.args.has("json") { print(Export.json(Status(roots: roots, preferences: prefs, complete: complete, issues: apps.issues + roots.compactMap(\.issue)))) }
            else { print("Indexed \(apps.items.count) applications and \(roots.reduce(0) { $0 + $1.count }) file entries."); for root in roots { if let issue = root.issue { print(issue) } } }
            if !apps.complete || roots.contains(where: { !$0.available || $0.issue != nil }) { throw CLIError("Search indexing is incomplete; inspect search status --json.", exitCode: 3) }
            return
        }
        let query = (sub == "query" ? Array(arguments.dropFirst()) : arguments).joined(separator: " ")
        guard let limit = Int(app.args.options["limit"] ?? "50"), (1...200).contains(limit) else { throw CLIError("--limit must be 1…200") }
        let result = try store.query(query, limit: limit)
        if app.args.has("json") { print(Export.json(result)) }
        else {
            for item in result.items { print("\(item.kind.rawValue)\t\(item.name)\t\(item.path)") }
            for issue in result.issues { FileHandle.standardError.write(Data((issue + "\n").utf8)) }
        }
        if !result.complete { throw CLIError("Search coverage is incomplete; inspect search status --json.", exitCode: 3) }
    }
}
