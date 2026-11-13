import AgentCore
import AppKit
import CleanKit
import SwiftUI
import ThermoL10n

/// The AI's reading of the relief plan, kept across page switches. It is the check-up's request,
/// narrowed to the memory diagnosis, and shares its consent: the same facts leave the app.
@MainActor final class MemoryReliefAdvice: ObservableObject {
    static let shared = MemoryReliefAdvice()

    enum Phase: Equatable { case idle, preview, asking, failed(String) }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var report: CheckupReport?
    @Published private(set) var snapshot: CheckupSnapshot?

    func start(_ diagnosis: SlowdownDiagnosis) {
        guard phase != .asking else { return }
        snapshot = CheckupSnapshot(uptime: ProcessInfo.processInfo.systemUptime, diagnosis: diagnosis)
        if CheckupModel.shared.consented { ask() } else { phase = .preview }
    }

    func send() { CheckupModel.shared.consented = true; ask() }
    func cancel() { if phase != .asking { phase = .idle } }

    /// Offscreen snapshots only: show a saved AI answer for the diagnosis fixture without asking anyone.
    func loadFixture(answer path: String) {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8),
              let diagnosis = ProcessInfo.processInfo.environment["THERMO_DIAGNOSIS_FIXTURE"]
                .flatMap({ FileManager.default.contents(atPath: $0) })
                .flatMap({ try? JSONDecoder().decode(SlowdownDiagnosis.self, from: $0) }) else { return }
        report = LocalAI.parseCheckup(raw, snapshot: CheckupSnapshot(diagnosis: diagnosis), source: "fixture")
    }

    private func ask() {
        guard let snapshot, let backend = LocalAIStore.shared.backend else {
            phase = .failed(tr("No AI found on this Mac.")); return
        }
        phase = .asking
        Task {
            do { report = try await LocalAI.checkup(snapshot, using: backend); phase = .idle }
            catch { phase = .failed(error.localizedDescription) }
        }
    }

    func finding(for step: MemoryReliefPlan.Step) -> CheckupFinding? {
        report?.findings.first { $0.culprit?.id == step.id }
    }
}

/// "Free memory": what can go without touching the work in progress behind one button, then the
/// apps and sessions that are the person's call, each with what acting on it costs.
struct MemoryReliefCard: View {
    /// The program rows of the Memory page, to hand an app step to the page's own quit and restart sheets.
    let programs: [MemoryProgram]
    let quit: (MachinePulse.Hog) -> Void
    let restart: (MachinePulse.Hog) -> Void
    let inspect: (String) -> Void
    let acted: () -> Void

    @ObservedObject private var recorder = PulseRecorder.shared
    @ObservedObject private var pulse = SystemPulse.shared
    @ObservedObject private var advice = MemoryReliefAdvice.shared
    @ObservedObject private var ai = LocalAIStore.shared
    @State private var confirming: MemoryReliefPlan?
    @State private var working = false
    @State private var feedback: String?

    var body: some View {
        // An empty view never appears, so the triggers hang off a container that always exists.
        VStack(spacing: 0) { content }
            .onAppear {
                ai.discover()
                if recorder.diagnosis.map({ Date().timeIntervalSince($0.sampled) > 30 }) ?? true { recorder.diagnoseNow() }
            }
    }

    @ViewBuilder var content: some View {
        if let d = recorder.diagnosis, d.memoryStrain != .none || feedback != nil {
            let plan = MemoryReliefPlan(d)
            if !plan.steps.isEmpty || feedback != nil {
                VStack(alignment: .leading, spacing: 0) {
                    header(d, plan)
                    if advice.phase == .preview, let s = advice.snapshot { divider; preview(s) }
                    if case .failed(let why) = advice.phase { divider; note(why, symbol: "exclamationmark.triangle") }
                    if let r = advice.report, advice.phase != .preview { divider; summary(r) }
                    ForEach(plan.steps) { step in
                        divider
                        row(step)
                    }
                    if let feedback { divider; note(feedback, symbol: "checkmark.circle") }
                }
                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.caution.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.caution.opacity(0.22)))
                .sheet(item: $confirming) { plan in
                    ConfirmSheet(title: tr("Free about %1$@?", MemoryFormat.string(kibibytes: plan.safeKB)),
                                 summary: tr("Only processes nobody is using are ended: tool copies whose session is gone or has been idle for over 2 hours, and leftovers whose parent exited. Each is asked to stop (SIGTERM) and forced after 5 seconds (SIGKILL). Apps and AI agent sessions are not touched."),
                                 destructive: true, heading: tr("What will run"),
                                 lines: plan.safe.flatMap { s in (s.culprit.identities ?? []).map { "kill -TERM \($0.pid)  # \(s.culprit.name)" } },
                                 detailLines: plan.safe.map { "\($0.culprit.name): \($0.culprit.evidence)" },
                                 footnote: tr("Thermo checks again right before it acts: a process whose session became active in the meantime is left alone. A session whose tool copy was ended loses that tool until it is restarted."),
                                 confirmTitle: tr("Free memory"),
                                 confirm: { confirming = nil; run(plan) }, cancel: { confirming = nil })
                }
            }
        }
    }

    var divider: some View { InspectorDivider(inset: Theme.Space.l) }

    func note(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).font(Theme.secondary).foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s)
    }

    func header(_ d: SlowdownDiagnosis, _ plan: MemoryReliefPlan) -> some View {
        let state = SlowdownCulpritsCard.split(d.headline).0
        let safe = plan.safe
        let count = safe.reduce(0) { $0 + ($1.culprit.identities?.count ?? 0) }
        return HStack(alignment: .top, spacing: Theme.Space.m) {
            ZStack {
                Circle().fill(Theme.caution.opacity(0.16))
                Image(systemName: "bolt.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.caution)
            }
            .frame(width: 28, height: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(state).font(Theme.heading).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                Text(safe.isEmpty
                     ? tr("Nothing can be freed without interrupting something. The steps below are yours to decide, biggest first.")
                     : tr("%1$@ idle or leftover processes hold about %2$@ and can go without interrupting your work. The rest is yours to decide.",
                          String(count), MemoryFormat.string(kibibytes: plan.safeKB)))
                    .font(Theme.secondary).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.s)
            VStack(alignment: .trailing, spacing: Theme.Space.s) {
                if !safe.isEmpty {
                    Button(working ? tr("Freeing…") : tr("Free %1$@", MemoryFormat.string(kibibytes: plan.safeKB))) { confirming = plan }
                        .buttonStyle(PillButtonStyle(prominent: true, color: Theme.caution)).disabled(working)
                }
                if let backend = ai.backend, !renderingPreview {
                    Button {
                        advice.start(d)
                    } label: {
                        if advice.phase == .asking {
                            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(tr("Asking…")) }
                        } else {
                            Label(advice.report == nil ? tr("Ask AI") : tr("Ask again"), systemImage: "sparkles")
                        }
                    }
                    .buttonStyle(PillButtonStyle()).controlSize(.small).disabled(advice.phase == .asking || advice.phase == .preview)
                    .help(tr("%1$@ says for each step what it does to your work in progress. Advice only: it never ends anything.", backend.label))
                }
            }
        }
        .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
    }

    func preview(_ s: CheckupSnapshot) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(tr("Sent to %1$@", ai.backend?.label ?? "")).font(Theme.sectionTitle).foregroundStyle(Theme.textSecondary)
            ScrollView {
                Text(s.facts).font(Theme.mono).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }.frame(maxHeight: 220)
            Text(tr("Readings, program names and project folders Thermo flagged; never file contents. The AI may pass them to the cloud model it uses."))
                .font(Theme.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(tr("Send")) { advice.send() }.buttonStyle(PillButtonStyle(prominent: true))
                Button(tr("Cancel")) { advice.cancel() }.buttonStyle(PillButtonStyle())
            }
        }
        .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
    }

    func summary(_ r: CheckupReport) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                .frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(r.summary).font(Theme.secondary).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(tr("AI answer · %1$@ · %2$@", r.source, AgeFormat.string(r.made)) + " · "
                     + tr("AI can be wrong. Thermo's own checks still apply when you act."))
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
    }

    static func tag(_ tier: MemoryReliefPlan.Tier) -> (String, Color) {
        switch tier {
        case .safe: return (tr("Does not interrupt work"), Theme.good)
        case .ask: return (tr("Closes an app"), Theme.caution)
        case .manual: return (tr("Your call"), Theme.textSecondary)
        }
    }

    func row(_ step: MemoryReliefPlan.Step) -> some View {
        let c = step.culprit
        let (label, color) = Self.tag(step.tier)
        let (lead, rest) = SlowdownCulpritsCard.split(c.guidance)
        return HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: step.tier == .safe ? "checkmark.circle.fill" : step.tier == .ask ? "macwindow" : "hand.raised")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(color)
                .frame(width: 28, alignment: .center).padding(.top, 1).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text(c.name).font(Theme.body.weight(.semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(tr("frees ~%1$@", MemoryFormat.string(kibibytes: c.freesKB)))
                        .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.caution).fixedSize()
                    StatusTag(text: label, color: color).fixedSize()
                    Spacer(minLength: Theme.Space.s)
                    action(step)
                }
                Text(lead).font(Theme.secondary).foregroundStyle(Theme.textSecondary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                if let f = advice.finding(for: step), !f.impact.isEmpty {
                    let (verdict, tone) = CheckupPage.safety(f.safety)
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                        Label(tr("AI advice: %1$@", verdict), systemImage: "sparkles").font(Theme.label).foregroundStyle(tone)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(tone.opacity(0.15))).fixedSize()
                        Text(f.impact).font(Theme.secondary).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if (step.tier == .safe && f.safety != .safe) || (step.tier != .safe && f.safety == .safe) {
                        Text(tr("AI advice differs from Thermo’s checks. Review the impact before acting; AI never changes which processes the button can end."))
                            .font(Theme.caption).foregroundStyle(Theme.caution).fixedSize(horizontal: false, vertical: true)
                    }
                }
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        if !rest.isEmpty { Text(rest).font(Theme.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true) }
                        Text(c.evidence).font(Theme.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                        if let sessions = c.sessions, !sessions.isEmpty {
                            Text(sessions.prefix(12).joined(separator: "\n")).font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
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

    /// The Memory page's own row for the app, which carries the identity its quit and restart check.
    func target(_ c: SlowdownCulprit) -> MachinePulse.Hog? {
        guard let app = c.app else { return nil }
        return programs.lazy.compactMap(\.actionTarget).first { $0.app == app && $0.quittable }
    }

    @ViewBuilder func action(_ step: MemoryReliefPlan.Step) -> some View {
        let c = step.culprit
        switch step.tier {
        case .safe:
            EmptyView()
        case .ask:
            if let h = target(c) {
                HStack(spacing: 6) {
                    Button(pulse.restarting == h.name ? tr("Restarting…") : tr("Restart")) { restart(h) }
                        .buttonStyle(PillButtonStyle(color: Theme.caution)).controlSize(.small)
                        .disabled(pulse.restarting != nil || pulse.quitting.contains(h.id))
                    Button(pulse.quitting.contains(h.id) ? tr("Stopping…") : tr("Quit")) { quit(h) }
                        .buttonStyle(PillButtonStyle()).controlSize(.small)
                        .disabled(pulse.quitting.contains(h.id) || pulse.restarting == h.name)
                }
            } else {
                Button(tr("Show processes")) { inspect(c.name) }.buttonStyle(PillButtonStyle()).controlSize(.small)
            }
        case .manual:
            if c.kind != .agentSessions, let program = c.program ?? c.name.components(separatedBy: " ").first {
                Button(tr("Show processes")) { inspect(program) }.buttonStyle(PillButtonStyle()).controlSize(.small)
            } else if let command = c.command {
                Button(tr("Copy command")) {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string)
                }.buttonStyle(PillButtonStyle()).controlSize(.small)
            }
        }
    }

    func run(_ plan: MemoryReliefPlan) {
        working = true; feedback = nil
        let confirmed = plan.safeIdentities
        recorder.diagnoseFresh { fresh, processes in
            // Off the recorder's queue: waiting for processes to stop must not hold up its ticks.
            DispatchQueue.global(qos: .userInitiated).async {
                let targets = MemoryRelief.targets(confirmed: confirmed, fresh: fresh)
                let outcome = MemoryRelief.end(targets, skipped: confirmed.count - targets.count, live: processes)
                DispatchQueue.main.async {
                    working = false; feedback = outcome.summary
                    PulseRecorder.shared.diagnoseNow()
                    acted()
                }
            }
        }
    }
}

extension MemoryReliefPlan: Identifiable {
    public var id: String { steps.map(\.id).joined(separator: "|") }
}
