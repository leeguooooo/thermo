import AgentCore
import Foundation

/// The Memory page's answer to "what do I do about it": the slowdown diagnosis sorted by what acting
/// costs the person. `safe` steps end only processes nobody is using (leftover or long-idle tool
/// copies), so one button can do all of them; `ask` steps quit or restart an app, one confirmation
/// each; `manual` steps are the person's call (agent sessions are never ended from here).
public struct MemoryReliefPlan: Sendable, Equatable {
    public enum Tier: String, Sendable {
        case safe, ask, manual
        var rank: Int { switch self { case .safe: 0; case .ask: 1; case .manual: 2 } }
    }

    public struct Step: Sendable, Equatable, Identifiable {
        public var id: String { culprit.id }
        public var tier: Tier
        public var culprit: SlowdownCulprit
    }

    /// Below this a step is not worth a row.
    public static let floorKB = 64 * 1024

    public var steps: [Step]

    public init(_ d: SlowdownDiagnosis) {
        var seen = Set<String>()
        steps = (d.culprits + d.also).filter { $0.freesKB >= Self.floorKB && seen.insert($0.id).inserted }
            .map { Step(tier: Self.tier($0), culprit: $0) }
            .sorted { a, b in
                a.tier != b.tier ? a.tier.rank < b.tier.rank
                    : a.culprit.freesKB != b.culprit.freesKB ? a.culprit.freesKB > b.culprit.freesKB : a.id < b.id
            }
    }

    /// One-click ending is only for what holds memory while nobody uses it. A busy process (`runaway`)
    /// may be the person's build: it stays a decision of its own, on the Overview.
    static func tier(_ c: SlowdownCulprit) -> Tier {
        switch c.action {
        case .end: return [.idleMCP, .orphan, .stuck].contains(c.kind) && c.identities?.isEmpty == false ? .safe : .manual
        case .quitApp, .restartApp: return c.app != nil ? .ask : .manual
        case .review: return .manual
        }
    }

    public var safe: [Step] { steps.filter { $0.tier == .safe } }
    public var safeKB: Int { safe.reduce(0) { $0 + $1.culprit.freesKB } }
    public var safeIdentities: [ProcessIdentity] { safe.flatMap { $0.culprit.identities ?? [] } }
}

public enum MemoryRelief {
    public struct Outcome: Sendable {
        public var results: [SlowdownFix.Result]
        /// Confirmed by the person but no longer safe a moment later (its session woke up, it exited): left alone.
        public var skipped: Int
        public var swapBefore: UInt64?
        public var swapAfter: UInt64?

        public var ended: Int { results.filter { $0.outcome == .stopped || $0.outcome == .killed }.count }
        public var freedKB: Int { results.reduce(0) { $0 + $1.freedKB } }

        public var summary: String {
            var text = results.isEmpty ? tr("Nothing was ended: none of the processes still qualified when checked again.")
                : tr("Ended %1$@ of %2$@ processes; about %3$@ freed.", String(ended), String(results.count), MemoryFormat.string(kibibytes: freedKB))
            if skipped > 0, !results.isEmpty {
                text = MachinePulse.sentences(text, tr("%1$@ were left alone: they no longer qualified when checked again.", String(skipped)))
            }
            if let before = swapBefore, let after = swapAfter, !results.isEmpty {
                text = MachinePulse.sentences(text, tr("Swap used: %1$@ → %2$@.", MemoryFormat.string(bytes: before), MemoryFormat.string(bytes: after)))
            }
            return text
        }
    }

    /// What may still be ended: the confirmed processes that a diagnosis made after the confirmation
    /// names again as safe. Anything that changed in between (a session became active, a PID was
    /// reused) drops out; nothing is ever added.
    public static func targets(confirmed: [ProcessIdentity], fresh: SlowdownDiagnosis) -> [ProcessIdentity] {
        let still = MemoryReliefPlan(fresh).safeIdentities
        return confirmed.filter { still.contains($0) }
    }

    /// Ends `targets` side by side (each waits up to 5 s for SIGTERM), then writes one journal record.
    public static func end(_ targets: [ProcessIdentity], skipped: Int, live: [SlowdownProcess], journalHome: String = NSHomeDirectory()) -> Outcome {
        let before = SlowdownSystem.read().swapUsed
        let byPID = Dictionary(live.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let lock = NSLock()
        var results = [SlowdownFix.Result?](repeating: nil, count: targets.count)
        DispatchQueue.concurrentPerform(iterations: targets.count) { i in
            let identity = targets[i]
            let r = byPID[identity.pid].map { SlowdownFix.end($0, identity: identity, record: false) }
                ?? SlowdownFix.Result(pid: identity.pid, name: (identity.executable as NSString).lastPathComponent, outcome: .changed,
                                      freedKB: 0, swapBefore: nil, swapAfter: nil, loadBefore: 0, loadAfter: nil)
            lock.lock(); results[i] = r; lock.unlock()
        }
        let done = results.compactMap { $0 }
        if !done.isEmpty {
            OperationJournal.record(OperationRecord(feature: "memory", action: "relief", subject: nil, items: done.map { r in
                .init(target: "\(r.name) · PID \(r.pid)", bytes: Int64(r.freedKB) * 1024,
                      status: r.outcome == .stopped || r.outcome == .killed ? "done" : "failed", detail: r.outcome.rawValue)
            }), home: journalHome)
        }
        return Outcome(results: done, skipped: skipped, swapBefore: before, swapAfter: SlowdownSystem.read().swapUsed)
    }
}
