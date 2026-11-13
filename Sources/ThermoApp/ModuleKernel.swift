import AgentCore
import AppKit
import CleanKit
import ModuleHost
import ModuleKit
import SwiftUI
import ThermoL10n

/// What Thermo does for its modules. A module holds no grant of its own; every request it makes
/// arrives here through its broker, is checked against its manifest, confirmed by the person where
/// it changes the Mac, and written to that module's access log.
enum ModuleKernel {
    static let log = ModuleAccessLog()

    static func make(for manifest: ModuleManifest) -> KernelXPC {
        BrokerKernel(broker: broker(for: manifest, log: log, confirm: { request in await confirm(request) }))
    }

    static func broker(for manifest: ModuleManifest, log: ModuleAccessLog, home: String = NSHomeDirectory(),
                       confirm: @escaping CapabilityBroker.Confirm) -> CapabilityBroker {
        CapabilityBroker(manifest: manifest, home: home, log: log, handlers: [
            .filesRead: KernelServices.filesRead,
            .filesDelete: KernelServices.filesDelete,
            .networkConnect: KernelServices.networkConnect(),
            .processesRead: processesRead,
            .processesEnd: processesEnd,
        ], rules: [
            .filesDelete: { request in try deletable(request, home: home) },
            .processesEnd: { request in _ = try endable(request) },
        ], confirm: confirm)
    }

    /// The places disk cleanup never touches are closed to modules too, whatever their manifest
    /// says: keys, documents, agent memory, and everything on the person's own protection list.
    static func deletable(_ request: BrokerRequest, home: String) throws {
        let guardian = Guard(home: home)
        for target in request.targets {
            if let why = guardian.refusal(target) ?? Whitelist.refusal(target, home: home) {
                throw BrokerError(.denied, "\(target) is protected: \(why)")
            }
        }
    }

    /// Thermo's own app, helpers and modules.
    static func ownProcess(_ executable: String?) -> Bool {
        guard let executable else { return false }
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath().path + "/"
        return URL(fileURLWithPath: executable).resolvingSymlinksInPath().path.hasPrefix(bundle)
    }

    /// The live processes a request names, or a refusal if any of them is one Thermo never ends:
    /// system processes, AI agent sessions, apps, and anything of Thermo's own. A process that is
    /// gone or whose PID was reused is not in the answer.
    static func endable(_ request: BrokerRequest) throws -> [(process: SlowdownProcess, identity: ProcessIdentity)] {
        guard request.operation == "end" else { throw BrokerError(.failed, "processes.end has no operation \(request.operation)") }
        let wanted = named(request)
        guard !wanted.isEmpty, wanted.count <= 200 else { throw BrokerError(.failed, "end takes 1 to 200 processes with pid and start time") }
        let live = Dictionary(SlowdownSampler().sample().map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var found: [(process: SlowdownProcess, identity: ProcessIdentity)] = []
        for (pid, started) in wanted {
            guard let identity = ProcessTable.identity(pid), abs(identity.started.timeIntervalSince(started)) < 0.001 else { continue }
            // A process the sampler does not list (another user's, a system one) is not ours to end.
            guard let process = live[pid], SlowdownFix.endable(process), !ownProcess(identity.executable) else {
                throw BrokerError(.denied, "Thermo does not end system processes, AI agent sessions, apps or itself (PID \(pid))")
            }
            found.append((process, identity))
        }
        return found
    }

    /// `processes.read`: `list` answers with every process of this user that Thermo can see.
    static let processesRead: CapabilityBroker.Handler = { request in
        guard request.operation == "list" else { throw BrokerError(.failed, "processes.read has no operation \(request.operation)") }
        let rows: [[String: Any]] = SlowdownSampler().sample().map { p in
            var row: [String: Any] = ["pid": Int(p.pid), "name": SlowdownDiagnosis.friendlyName(p), "memoryKB": p.footprintKB,
                                      "endable": SlowdownFix.endable(p) && !ownProcess(p.executable)]
            if let started = p.started { row["started"] = started.timeIntervalSince1970 }
            if let executable = p.executable { row["executable"] = executable }
            return row
        }
        return BrokerAnswer(try JSONSerialization.data(withJSONObject: ["processes": rows]))
    }

    /// The processes an end request names: `{"processes": [{"pid": 1, "started": 1700000000.5}]}`.
    /// The start time makes sure a reused PID is never mistaken for the process the module saw.
    static func named(_ request: BrokerRequest) -> [(pid: Int32, started: Date)] {
        guard case let .array(list)? = request.payload["processes"] else { return [] }
        return list.compactMap { item in
            guard case let .object(fields) = item, let pid = fields["pid"]?.number, let started = fields["started"]?.number else { return nil }
            return (Int32(pid), Date(timeIntervalSince1970: started))
        }
    }

    /// `processes.end`: `end`. The rule is checked again here, a moment after the person said yes.
    static let processesEnd: CapabilityBroker.Handler = { request in
        let targets = try endable(request)
        var results: [[String: Any]] = named(request).filter { item in !targets.contains { $0.identity.pid == item.pid } }
            .map { ["pid": Int($0.pid), "outcome": SlowdownFix.Outcome.changed.rawValue] }
        var ended: [String] = []
        // Side by side: each may take up to five seconds to quit.
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: targets.count) { index in
            let result = SlowdownFix.end(targets[index].process, identity: targets[index].identity)
            lock.lock(); defer { lock.unlock() }
            results.append(["pid": Int(result.pid), "name": result.name, "outcome": result.outcome.rawValue, "freedKB": result.freedKB])
            if result.outcome == .stopped || result.outcome == .killed { ended.append("\(result.name) · PID \(result.pid)") }
        }
        return BrokerAnswer(try JSONSerialization.data(withJSONObject: ["results": results]), acted: ended)
    }

    /// What the person is asked before a module deletes files or ends processes. Built from the
    /// request the kernel checked, never from text the module supplied.
    static func confirmation(_ request: BrokerRequest, names: [String]) -> (title: String, detail: String, action: String) {
        let name = request.manifest.localized(L10n.current.rawValue).name
        let shown = names.prefix(8).joined(separator: "\n")
        let more = names.count > 8 ? "\n" + tr("…and %1$@ more", String(names.count - 8)) : ""
        switch request.kind {
        case .filesDelete:
            return (tr("%1$@ wants to move %2$@ items to the Trash", name, String(names.count)), shown + more, tr("Move to Trash"))
        case .processesEnd:
            return (tr("%1$@ wants to end %2$@ processes", name, String(names.count)), shown + more, tr("End"))
        default:
            return (tr("%1$@ wants to change this Mac", name), request.kind.rawValue, tr("Allow"))
        }
    }

    @MainActor static func confirm(_ request: BrokerRequest) async -> Bool {
        var names = request.targets
        if request.kind == .processesEnd {
            names = named(request).map { item in
                let path = ProcessTable.identity(item.pid)?.executable ?? ""
                return "\((path as NSString).lastPathComponent) · PID \(item.pid)"
            }
        }
        let text = confirmation(request, names: names)
        let alert = NSAlert()
        alert.messageText = text.title
        alert.informativeText = text.detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: text.action)
        alert.addButton(withTitle: tr("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Settings: what one module has read, deleted, reached and ended through Thermo.
struct ModuleActivityView: View {
    let manifest: ModuleManifest
    let close: () -> Void
    @State private var summary = ModuleAccessLog.Summary()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Text(tr("What %1$@ did through Thermo", manifest.name)).font(Theme.heading)
                Spacer()
                Button(tr("Done"), action: close).keyboardShortcut(.defaultAction)
            }
            if summary == ModuleAccessLog.Summary() {
                Text(tr("Nothing yet.")).font(Theme.body).foregroundStyle(Theme.textSecondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    group(tr("Files read"), summary.read)
                    group(tr("Moved to the Trash"), summary.deleted)
                    group(tr("Connected to"), summary.hosts)
                    group(tr("Ended"), summary.ended)
                    if summary.denied + summary.declined + summary.failed > 0 {
                        Text(tr("%1$@ requests were refused, %2$@ were not confirmed and %3$@ failed.",
                                String(summary.denied), String(summary.declined), String(summary.failed)))
                            .font(Theme.secondary).foregroundStyle(Theme.textSecondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24).frame(width: 560, height: 440).foregroundStyle(Theme.textPrimary).background(Theme.canvas).preferredColorScheme(.dark)
        .task {
            let id = manifest.id
            summary = await Task.detached { ModuleKernel.log.summary(module: id) }.value
        }
    }

    @ViewBuilder func group(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.label).foregroundStyle(Theme.textTertiary)
                ForEach(items.suffix(200), id: \.self) { item in
                    Text(item).font(Theme.mono).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
        }
    }
}
