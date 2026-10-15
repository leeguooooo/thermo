import AgentCore
import CleanKit
import Foundation
import ThermoL10n

/// `thermo history`: every change Thermo made, newest first, and where each one is undone.
struct HistoryCommand {
    let app: App

    func run(_ rest: [String]) throws {
        switch rest.first {
        case nil, "list": try list()
        case "show": try show(rest.dropFirst().first)
        default: throw CLIError("usage: thermo history [list|show ID] [--limit N] [--json]")
        }
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; e.dateEncodingStrategy = .iso8601; return e
    }

    func list() throws {
        let limit = try app.args.options["limit"].map { value -> Int in
            guard let n = Int(value), (1...1000).contains(n) else { throw CLIError("--limit takes 1–1000") }
            return n
        } ?? 20
        let records = OperationJournal.read(limit: limit)
        if app.args.has("json") {
            struct Output: Encodable { let journal: String; let limit: Int; let operations: [OperationRecord] }
            print(String(decoding: try Self.encoder().encode(Output(journal: OperationJournal.url().path, limit: limit, operations: records)), as: UTF8.self))
            return
        }
        let style = app.style
        guard !records.isEmpty else { print(style.dim(tr("No operations recorded yet."))); return }
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short
        for r in records {
            let mark = r.outcome == "succeeded" ? style.green("✓") : r.outcome == "partial" ? style.yellow("◐") : style.red("✗")
            let meta = [String(r.id.prefix(8)), f.string(from: r.time), r.items.count > 1 ? tr("%1$@ items", String(r.items.count)) : nil, r.sizeText].compactMap { $0 }
            print("\(mark) \(style.bold(r.title))" + (r.subject.map { "  " + $0 } ?? "") + style.dim("  " + meta.joined(separator: " · ")))
            if let undo = r.undoText { print(style.dim("    " + undo)) }
        }
        print(style.dim(tr("Details: thermo history show ID · log: %1$@", FS.tilde(OperationJournal.url().path))))
    }

    func show(_ id: String?) throws {
        guard let id, let r = OperationJournal.find(id) else { throw CLIError("usage: thermo history show ID (see thermo history)") }
        if app.args.has("json") { print(String(decoding: try Self.encoder().encode(r), as: UTF8.self)); return }
        let style = app.style
        print(style.bold(r.title) + style.dim("  \(r.id) · \(r.outcomeText)"))
        if let subject = r.subject { print(style.dim("  " + subject)) }
        for item in r.items {
            let mark = item.status == "done" ? style.green("✓") : item.status == "partial" ? style.yellow("◐") : item.status == "skipped" ? style.dim("–") : style.red("✗")
            let size = item.bytes.map { "  " + ByteFormat.string($0) } ?? ""
            print("  \(mark) \(item.target)" + style.dim(size + (item.detail.map { "  " + $0 } ?? "")))
        }
        if let size = r.sizeText { print(style.dim("  " + size)) }
        if let undo = r.undoText { print("  " + undo) }
    }
}
