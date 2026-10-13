import CleanKit
import Foundation

struct TabsCommand {
    let app: App
    func run(_ rest: [String]) throws {
        let sub = rest.first ?? "list"
        let browser = app.args.options["app"] ?? "Google Chrome"
        let count = rest.isEmpty ? 1 : rest.count
        if ["list", "groups", "archive", "saved"].contains(sub), count != 1 { throw CLIError("Unexpected positional argument. Use explicit --ids, --group or --window options.") }
        if sub == "restore", app.args.options["ids"] != nil || app.args.options["group"] != nil || app.args.has("all-windows") { throw CLIError("restore accepts a saved batch UUID and an optional --window, not a tab selection.") }
        switch sub {
        case "saved": try emit(TabWorkspace.archives())
        case "show": try emit(saved(rest))
        case "restore":
            let saved = try saved(rest)
            guard !app.args.has("dry-run") else { try emit(saved); return }
            try approve("Reopen \(saved.remaining) saved web pages? Unsaved input is not restored.")
            try emit(TabWorkspace.restore(saved.id, destinationWindow: try app.args.int("window")))
        case "list", "groups", "group", "archive":
            let inventory = try blocking { try await TabWorkspace.inventory(app: browser) }
            if sub == "list" || sub == "groups" { try emit(inventory); return }
            let selected = try select(inventory, archive: sub == "archive")
            guard !selected.isEmpty else { throw CLIError("No matching unprotected tabs. Run thermo tabs list --json to see the protection reasons.") }
            if app.args.has("dry-run") { try emit(selected); return }
            if sub == "group" {
                guard app.args.has("by-site") || rest.count == 2 else { throw CLIError("usage: thermo tabs group NAME --ids ID,ID [--yes] or group --by-site") }
                try approve("Group \(selected.count) tabs in Thermo? Browser windows stay in place.")
                try TabWorkspace.assign(selected, name: app.args.has("by-site") ? nil : rest[1])
                try emit(try blocking { try await TabWorkspace.inventory(app: browser) })
            } else {
                try approve("Save and close \(selected.count) background tabs? Unsaved input may be lost. Web links and Thermo groups are saved locally.")
                try emit(try blocking { try await TabWorkspace.archive(selected, app: browser, name: app.args.options["name"] ?? app.args.options["group"] ?? "Saved tabs") })
            }
        default: throw CLIError("unknown tabs command '\(sub)' (list, groups, group, archive, saved, show, restore)")
        }
    }
    func select(_ inventory: TabWorkspace.Inventory, archive: Bool) throws -> [TabWorkspace.Page] {
        let ids = app.args.options["ids"].map { Set($0.split(separator: ",").map(String.init)) }
        if let ids, !ids.isSubset(of: Set(inventory.pages.map(\.id))) { throw CLIError("Some tab IDs are stale or unknown. Refresh thermo tabs list.") }
        let window = try app.args.int("window") ?? ((app.args.has("all-windows") || ids != nil) ? nil : inventory.pages.first?.tab.window)
        return inventory.pages.filter {
            (window == nil || $0.tab.window == window) &&
            (ids == nil || ids!.contains($0.id)) &&
            (app.args.options["group"] == nil || $0.group == app.args.options["group"]) &&
            (!archive || $0.canArchive)
        }
    }
    func saved(_ rest: [String]) throws -> TabWorkspace.Archive {
        guard rest.count == 2, let id = UUID(uuidString: rest[1]),
              let value = try TabWorkspace.archives().first(where: { $0.id == id }) else { throw CLIError("Use a saved batch UUID from thermo tabs saved.") }
        return value
    }
    func approve(_ text: String) throws {
        if app.args.has("yes") { return }
        guard !app.args.has("json"), isatty(STDIN_FILENO) != 0 else { throw CLIError("Review --dry-run, then use --yes to execute.") }
        print(text + " [y/N] ", terminator: ""); fflush(stdout)
        guard ["y", "yes"].contains(readLine()?.lowercased() ?? "") else { throw CLIError("Cancelled. Nothing changed.") }
    }
    func emit<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }
    final class ResultBox<T>: @unchecked Sendable { var value: Result<T, Error>? }
    func blocking<T>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let box = ResultBox<T>(); let done = DispatchSemaphore(value: 0)
        Task.detached { do { box.value = .success(try await operation()) } catch { box.value = .failure(error) }; done.signal() }
        done.wait(); return try box.value!.get()
    }
}
