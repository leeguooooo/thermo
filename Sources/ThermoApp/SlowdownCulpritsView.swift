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
        content.onAppear { if recorder.diagnosis == nil { recorder.diagnoseNow() } }
    }

    @ViewBuilder var content: some View {
        if let d = recorder.diagnosis, !d.culprits.isEmpty, d.memoryStrain != .none || d.cpuStrain != .none || d.isReal {
            VStack(alignment: .leading, spacing: 6) {
                Text(d.headline).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                ForEach(d.culprits) { c in row(c) }
                if let feedback { Text(feedback).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
            .sheet(item: $confirming) { c in
                ConfirmSheet(title: c.action == .quitApp ? tr("Quit %1$@?", c.name) : tr("End %1$@?", c.name),
                             summary: c.action == .quitApp ? tr("The app is asked to quit, the same as ⌘Q; it can save your work first.")
                                : tr("The process is asked to stop (SIGTERM); if it is still running after 5 seconds it is forced to quit (SIGKILL). Unsaved work in it may be lost."),
                             destructive: c.action == .end, heading: tr("What will run"),
                             lines: c.action == .quitApp ? [tr("quit %1$@", c.app ?? c.name)] : ["kill -TERM \(c.pids[0])", tr("kill -KILL %1$@ if it does not stop", String(c.pids[0]))],
                             detailLines: [c.evidence] + (c.launcher.map { [tr("started by %1$@", $0)] } ?? []),
                             footnote: tr("Thermo never stops system processes, AI agent sessions or itself."),
                             confirmTitle: c.action == .quitApp ? tr("Quit") : tr("End"),
                             confirm: { confirming = nil; act(c) }, cancel: { confirming = nil })
            }
        }
    }

    func row(_ c: SlowdownCulprit) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(c.name).font(.callout).lineLimit(1)
                if c.freesKB >= 64 * 1024 {
                    Text(tr("frees ~%1$@", MemoryFormat.string(kibibytes: c.freesKB))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
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
            if let l = c.launcher { Text(l).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            Text(c.evidence).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(c.guidance).font(.caption).fixedSize(horizontal: false, vertical: true)
            if let sessions = c.sessions, !sessions.isEmpty {
                Text(sessions.prefix(8).joined(separator: "\n")).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
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
                let current = SlowdownSampler().sample(window: 0.5).first { $0.pid == c.pids[0] }
                if let p = current, let identity = c.identities?.first {
                    let r = SlowdownFix.end(p, identity: identity)
                    text = r.summary
                    if let before = r.swapBefore, let after = r.swapAfter {
                        text = MachinePulse.sentences(text, tr("Swap used: %1$@ → %2$@.", ByteFormat.string(Int64(before)), ByteFormat.string(Int64(after))))
                    }
                } else {
                    text = tr("PID %1$@ is no longer the process that was checked; nothing was sent.", String(c.pids[0]))
                }
            }
            DispatchQueue.main.async {
                working.remove(c.id); feedback = text
                recorder.diagnoseNow()
            }
        }
    }
}
