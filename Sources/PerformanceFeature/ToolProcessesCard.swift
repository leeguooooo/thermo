import ThermoUI
import AgentCore
import CleanKit
import SwiftUI
import ThermoL10n

/// Reads the tool processes AI agents keep (MCP servers, per-thread helpers) and ends the ones the
/// person picks. One reading takes about a second and no transcript or model, so it still answers
/// on a machine that is swapping.
@MainActor final class ToolProcessesModel: ObservableObject {
    @Published private(set) var groups: [ToolProcessGroup] = []
    @Published private(set) var working = false
    @Published var feedback: String?
    private var reading = false
    private let read: @Sendable () -> [SlowdownProcess]

    init(read: @escaping @Sendable () -> [SlowdownProcess] = { SlowdownSampler().sample(window: 1) }) { self.read = read }

    var rescueKB: Int { groups.reduce(0) { $0 + $1.rescueKB } }
    var rescueProcesses: Int { groups.reduce(0) { $0 + $1.rescueCopies.reduce(0) { $0 + $1.identities.count } } }
    var memoryKB: Int { groups.reduce(0) { $0 + $1.memoryKB } }

    func refresh() {
        guard !reading else { return }
        reading = true
        let read = read
        DispatchQueue.global(qos: .userInitiated).async {
            let found = ToolProcesses.inventory(read())
            DispatchQueue.main.async { self.groups = found; self.reading = false }
        }
    }

    /// Ends the confirmed processes that a fresh reading still lists the same way; nothing is added.
    func end(_ confirmed: [ProcessIdentity], rescueOnly: Bool, subject: String, done: @escaping @MainActor () -> Void) {
        guard !working else { return }
        working = true; feedback = nil
        let read = read
        DispatchQueue.global(qos: .userInitiated).async {
            let processes = read()
            let fresh = ToolProcesses.inventory(processes)
            let still = rescueOnly ? ToolProcesses.rescueIdentities(fresh) : fresh.flatMap(\.identities)
            let targets = confirmed.filter { still.contains($0) }
            let memory = Dictionary(processes.map { ($0.pid, $0.footprintKB) }, uniquingKeysWith: { a, _ in a })
            let outcome = ToolProcesses.end(targets, memoryKB: memory, subject: subject)
            let after = ToolProcesses.inventory(read())
            DispatchQueue.main.async {
                self.working = false; self.feedback = outcome.summary; self.groups = after
                done()
            }
        }
    }
}

enum ToolProcessesText {
    static func host(_ s: ToolProcesses.Summary) -> String {
        switch s.hostKind {
        case .none: return tr("starter has exited")
        case .sharedService: return tr("held by %1$@ (PID %2$@)", s.hostName, s.groups.compactMap(\.hostPID).map { String($0) }.joined(separator: ", "))
        case .session: return trCount(s.hosts, "in %1$@ %2$@ session", "in %1$@ %2$@ sessions", s.hostName)
        }
    }

    /// The folders of the sessions that hold it, for the confirmation: these lose the tool.
    static func folders(_ s: ToolProcesses.Summary) -> [String] {
        Array(Set(s.groups.compactMap { $0.hostProject.map { ($0 as NSString).abbreviatingWithTildeInPath } })).sorted()
    }

    static func age(_ seconds: TimeInterval) -> String {
        seconds >= 86_400 ? tr("%1$@ d", String(Int(seconds / 86_400)))
            : seconds >= 3600 ? tr("%1$@ h", String(Int(seconds / 3600))) : tr("%1$@ min", String(max(1, Int(seconds / 60))))
    }

    static let rescueSummary = tr("Ends the tool processes AI agents left behind: the ones whose starter has exited, and the ones a shared agent service has held for over an hour while they do nothing. Each is asked to stop (SIGTERM) and forced after 5 seconds (SIGKILL).")
    static let rescueFootnote = tr("AI agent sessions, apps and the tools of a session in a terminal are not touched. A thread that still uses one of these tools loses it until it is restarted.")
}

/// The Memory page's "tool processes" list: every MCP server and helper per host, with one button
/// for what was left behind and an End per row.
struct ToolProcessesCard: View {
    let acted: () -> Void
    @Environment(\.performanceOperations) private var operations
    @StateObject private var model = ToolProcessesModel()
    @State private var confirmingRescue = false
    @State private var ending: ToolProcesses.Summary?
    @State private var showAll = false

    var body: some View {
        VStack(spacing: 0) { content }.onAppear { model.refresh() }
    }

    @ViewBuilder var content: some View {
        if !model.groups.isEmpty || model.feedback != nil {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tr("Tool processes of AI agents")).font(Theme.sectionTitle)
                        Text(model.rescueProcesses > 0
                             ? tr("MCP servers and helpers use %1$@. %2$@ processes (%3$@) were left behind and can go without closing a session.",
                                  MemoryFormat.string(kibibytes: model.memoryKB), String(model.rescueProcesses), MemoryFormat.string(kibibytes: model.rescueKB))
                             : tr("MCP servers and helpers use %1$@. None of them was left behind; ending one takes that tool away from its session.",
                                  MemoryFormat.string(kibibytes: model.memoryKB)))
                            .font(Theme.secondary).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if model.rescueProcesses > 0 {
                        Button(model.working ? tr("Stopping…") : tr("End left behind…")) { confirmingRescue = true }
                            .buttonStyle(PillButtonStyle(prominent: true, color: Theme.danger)).controlSize(.small).disabled(model.working)
                    }
                }
                .padding(Theme.Space.l)
                let rows = ToolProcesses.summary(model.groups)
                ForEach(showAll ? rows : Array(rows.prefix(8))) { g in
                    InspectorDivider(inset: Theme.Space.l)
                    row(g)
                }
                if rows.count > 8 {
                    InspectorDivider(inset: Theme.Space.l)
                    Button(showAll ? tr("Show fewer") : tr("Show all %1$@", String(rows.count))) { showAll.toggle() }
                        .buttonStyle(.link).font(Theme.caption).padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s)
                }
                if let feedback = model.feedback {
                    InspectorDivider(inset: Theme.Space.l)
                    Label(feedback, systemImage: "checkmark.circle").font(Theme.secondary).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s)
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.surface))
            .sheet(isPresented: $confirmingRescue) {
                let targets = model.groups.filter { !$0.rescueCopies.isEmpty }
                ConfirmSheet(title: tr("End %1$@ left-behind tool processes?", String(model.rescueProcesses)),
                             summary: ToolProcessesText.rescueSummary, destructive: true, heading: tr("What will run"),
                             lines: ToolProcesses.summary(targets).map { "kill -TERM  \($0.name) ×\($0.rescueCopies)  # \(MemoryFormat.string(kibibytes: $0.rescueKB)) · \(ToolProcessesText.host($0))" },
                             footnote: ToolProcessesText.rescueFootnote, confirmTitle: tr("End them"),
                             confirm: { confirmingRescue = false; run(ToolProcesses.rescueIdentities(targets), rescueOnly: true, subject: "rescue") },
                             cancel: { confirmingRescue = false })
            }
            .sheet(item: $ending) { g in
                ConfirmSheet(title: tr("End %1$@ ×%2$@?", g.name, String(g.copies)),
                             summary: g.hostKind == .none
                                ? tr("Whatever started these has exited. Each is asked to stop (SIGTERM) and forced after 5 seconds (SIGKILL).")
                                : tr("%1$@ loses this tool until it is restarted or reconnects it (Claude Code: /mcp). Each process is asked to stop (SIGTERM) and forced after 5 seconds (SIGKILL).", g.hostName),
                             destructive: true, heading: tr("What will run"),
                             lines: g.groups.flatMap(\.copies).map { "kill -TERM \($0.identities.map { String($0.pid) }.joined(separator: " "))" },
                             detailLines: ToolProcessesText.folders(g),
                             footnote: tr("The session or service that holds them keeps running."), confirmTitle: tr("End"),
                             confirm: { ending = nil; run(g.identities, rescueOnly: false, subject: g.name) }, cancel: { ending = nil })
            }
        }
    }

    func row(_ g: ToolProcesses.Summary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: g.copies > 1 ? "\(g.name) ×\(g.copies)" : g.name).font(Theme.body)
                Text(ToolProcessesText.host(g) + " · " + tr("oldest %1$@", ToolProcessesText.age(g.oldest))
                     + (g.rescueCopies == 0 ? "" : " · " + tr("%1$@ left behind", String(g.rescueCopies))))
                    .font(Theme.caption).foregroundStyle(g.rescueCopies == 0 ? Theme.textSecondary : Theme.caution)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(MemoryFormat.string(kibibytes: g.memoryKB)).font(Theme.body.monospacedDigit()).foregroundStyle(Theme.textSecondary)
            Button(tr("End…")) { ending = g }.buttonStyle(PillButtonStyle()).controlSize(.small).disabled(model.working)
        }
        .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s)
    }

    func run(_ identities: [ProcessIdentity], rescueOnly: Bool, subject: String) {
        guard let operation = operations.begin() else { model.feedback = tr("This feature is switched off."); return }
        model.end(identities, rescueOnly: rescueOnly, subject: subject) { operations.end(operation); acted() }
    }
}

/// The menu bar panel's emergency: shown only while memory is under pressure and something was left
/// behind, so the way out is one click from the menu bar when the main window is too slow to open.
struct ToolRescueRow: View {
    let active: Bool
    let strained: Bool
    var indent: CGFloat = 0
    @Environment(\.performanceOperations) private var operations
    @StateObject private var model = ToolProcessesModel()
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.rescueProcesses > 0 && strained {
                HStack(alignment: .top, spacing: 6) {
                    Text(tr("AI agents left %1$@ tool processes behind (%2$@).", String(model.rescueProcesses), MemoryFormat.string(kibibytes: model.rescueKB)))
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button(model.working ? tr("Stopping…") : tr("End them…")) { confirming = true }
                        .controlSize(.small).modifier(ActionButtonStyle(prominent: true)).disabled(model.working)
                }
            }
            if let feedback = model.feedback {
                Text(feedback).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, indent)
        .onAppear { if active && strained { model.refresh() } }
        .onChange(of: active) { if $0 && strained { model.refresh() } }
        .onChange(of: strained) { if $0 && active { model.refresh() } }
        .sheet(isPresented: $confirming) {
            let targets = model.groups.filter { !$0.rescueCopies.isEmpty }
            ConfirmSheet(title: tr("End %1$@ left-behind tool processes?", String(model.rescueProcesses)),
                         summary: ToolProcessesText.rescueSummary, destructive: true, heading: tr("What will run"),
                         lines: ToolProcesses.summary(targets).map { "kill -TERM  \($0.name) ×\($0.rescueCopies)  # \(MemoryFormat.string(kibibytes: $0.rescueKB))" },
                         footnote: ToolProcessesText.rescueFootnote, confirmTitle: tr("End them"),
                         confirm: {
                             confirming = false
                             guard let operation = operations.begin() else { model.feedback = tr("This feature is switched off."); return }
                             model.end(ToolProcesses.rescueIdentities(targets), rescueOnly: true, subject: "rescue") { operations.end(operation) }
                         }, cancel: { confirming = false })
        }
    }
}
