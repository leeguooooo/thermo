import AgentCore
import AppKit
import CleanKit
import SwiftUI
import ThermoL10n

/// "Why is my Mac slow": the 1–3 culprits from the latest diagnosis, each with its fix. Ending asks
/// first, rechecks the process identity, then SIGTERM → SIGKILL; apps are only asked to quit.
struct SlowdownCulpritsCard: View {
    @ObservedObject private var recorder = PulseRecorder.shared
    @State private var confirming: SlowdownCulprit?
    @State private var working: Set<String> = []
    @State private var feedback: String?

    var body: some View {
        // An empty view never appears, so the trigger hangs off a container that always exists.
        VStack(spacing: 0) { content }.onAppear { if recorder.diagnosis == nil { recorder.diagnoseNow() } }
    }

    @ViewBuilder var content: some View {
        if let d = recorder.diagnosis, !d.culprits.isEmpty, d.memoryStrain != .none || d.cpuStrain != .none || d.isReal {
            VStack(alignment: .leading, spacing: 0) {
                header(d)
                ForEach(Array(d.culprits.enumerated()), id: \.element.id) { i, c in
                    InspectorDivider(inset: Theme.Space.l)
                    row(c, rank: i + 1)
                }
                if let feedback {
                    InspectorDivider(inset: Theme.Space.l)
                    Label(feedback, systemImage: "checkmark.circle").font(Theme.secondary).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s)
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.caution.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.caution.opacity(0.22)))
            .sheet(item: $confirming) { c in
                ConfirmSheet(title: c.action == .quitApp ? tr("Quit %1$@?", c.name) : tr("End %1$@?", c.name),
                             summary: c.action == .quitApp ? tr("The app is asked to quit, the same as ⌘Q; it can save your work first.")
                                : tr("The process is asked to stop (SIGTERM); if it is still running after 5 seconds it is forced to quit (SIGKILL). Unsaved work in it may be lost."),
                             destructive: c.action == .end, heading: tr("What will run"),
                             lines: c.action == .quitApp ? [tr("quit %1$@", c.app ?? c.name)] : (c.identities ?? []).flatMap { ["kill -TERM \($0.pid)", tr("kill -KILL %1$@ if it does not stop", String($0.pid))] },
                             detailLines: [c.evidence] + (c.launcher.map { [tr("started by %1$@", $0)] } ?? []),
                             footnote: tr("Thermo never stops system processes, AI agent sessions or itself."),
                             confirmTitle: c.action == .quitApp ? tr("Quit") : tr("End"),
                             confirm: { confirming = nil; act(c) }, cancel: { confirming = nil })
            }
        }
    }

    /// The headline's first sentence is the state ("memory is tight (swap …)"); the culprit names
    /// that follow it are already the rows below, so only the state and the total are shown here.
    func header(_ d: SlowdownDiagnosis) -> some View {
        // Sentence ends only: "。" or ". " — a bare "." is the decimal point in "16.7 GB".
        let state = d.headline.components(separatedBy: "。").first.flatMap { $0.components(separatedBy: ". ").first } ?? d.headline
        let total = d.culprits.reduce(0) { $0 + $1.freesKB }
        return HStack(alignment: .top, spacing: Theme.Space.m) {
            ZStack {
                Circle().fill(Theme.caution.opacity(0.16))
                Image(systemName: "exclamationmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.caution)
            }
            .frame(width: 28, height: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(state).font(Theme.heading).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                if total >= 64 * 1024 {
                    Text(tr("Handling the %1$@ items below frees about %2$@.", String(d.culprits.count), MemoryFormat.string(kibibytes: total)))
                        .font(Theme.secondary).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
    }

    func row(_ c: SlowdownCulprit, rank: Int) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Text("\(rank)").font(Theme.label.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                .frame(width: 28, alignment: .center).padding(.top, 1)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text(c.name).font(Theme.body.weight(.semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if c.freesKB >= 64 * 1024 {
                        Text(tr("frees ~%1$@", MemoryFormat.string(kibibytes: c.freesKB)))
                            .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.caution)
                    }
                    Spacer(minLength: Theme.Space.s)
                    action(c)
                }
                Text(c.guidance).font(Theme.secondary).foregroundStyle(Theme.textSecondary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        if let l = c.launcher { Text(l).font(Theme.caption).foregroundStyle(Theme.textTertiary) }
                        Text(c.evidence).font(Theme.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                        if let sessions = c.sessions, !sessions.isEmpty {
                            Text(sessions.prefix(8).joined(separator: "\n")).font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.top, Theme.Space.xs)
                } label: {
                    Text(tr("Details")).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
    }

    @ViewBuilder func action(_ c: SlowdownCulprit) -> some View {
        if c.action == .end || c.action == .quitApp {
            Button(working.contains(c.id) ? tr("Stopping…") : c.action == .quitApp ? tr("Quit") : tr("End")) { confirming = c }
                .controlSize(.small).modifier(ActionButtonStyle(prominent: c.action == .end))
                .disabled(working.contains(c.id))
        } else if let command = c.command {
            Button(tr("Copy command")) {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string)
            }.controlSize(.small).modifier(ActionButtonStyle(prominent: false))
        }
    }

    func act(_ c: SlowdownCulprit) {
        working.insert(c.id)
        let recorder = recorder
        DispatchQueue.global(qos: .userInitiated).async {
            var text: String
            if c.action == .quitApp {
                let asked = c.pids.compactMap { NSRunningApplication(processIdentifier: $0) }.first?.terminate() ?? false
                text = asked ? tr("Asked %1$@ to quit.", c.name) : tr("%1$@ did not accept the request to quit.", c.name)
            } else {
                let live = Dictionary(SlowdownSampler().sample(window: 0.5).map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
                // Every checked process the culprit names (idle MCP copies can be several), each rechecked.
                let results = (c.identities ?? []).map { identity -> SlowdownFix.Result in
                    guard let p = live[identity.pid] else {
                        return SlowdownFix.Result(pid: identity.pid, name: c.name, outcome: .changed, freedKB: 0, swapBefore: nil, swapAfter: nil, loadBefore: 0, loadAfter: nil)
                    }
                    return SlowdownFix.end(p, identity: identity)
                }
                text = results.count == 1 ? results[0].summary : results.isEmpty
                    ? tr("PID %1$@ is no longer the process that was checked; nothing was sent.", String(c.pids[0]))
                    : tr("Ended %1$@ of %2$@ processes; about %3$@ freed.", String(results.filter { $0.outcome == .stopped || $0.outcome == .killed }.count),
                         String(results.count), MemoryFormat.string(kibibytes: results.reduce(0) { $0 + $1.freedKB }))
                if let before = results.first?.swapBefore, let after = results.last?.swapAfter {
                    text = MachinePulse.sentences(text, tr("Swap used: %1$@ → %2$@.", ByteFormat.string(Int64(before)), ByteFormat.string(Int64(after))))
                }
            }
            DispatchQueue.main.async {
                working.remove(c.id); feedback = text
                recorder.diagnoseNow()
            }
        }
    }
}
