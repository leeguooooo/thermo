import AgentCore
import Foundation

/// A short follow-up after an explicit action. Observations, never a promise that the Mac is fixed.
public struct PulseActionReview: Codable, Sendable {
    public enum Action: String, Codable, Sendable { case quit, restart }
    public enum Outcome: String, Codable, Sendable { case stopped, stillRunning, notReopened, memoryDecreased, noClearDecrease, unavailable }
    public let action: Action
    public let program: String
    public let outcome: Outcome
    public let seconds: Double
    public let beforeMemoryKB: Int
    public let afterMemoryKB: Int?
    public let loadBefore: Double
    public let loadAfter: Double
    public let memoryBefore: MachinePulse.Memory
    public let memoryAfter: MachinePulse.Memory
    public let thermalBefore: MachinePulse.Thermal
    public let thermalAfter: MachinePulse.Thermal

    /// `afterTarget` must come from the full process inventory, including idle programs.
    public init(action: Action, target: MachinePulse.Hog, before: MachinePulse, after: MachinePulse,
                afterTarget: MachinePulse.Hog?, inventoryAvailable: Bool = true) {
        self.action = action
        program = target.name
        seconds = after.sampled.timeIntervalSince(before.sampled)
        beforeMemoryKB = target.memoryKB
        afterMemoryKB = afterTarget?.memoryKB
        loadBefore = before.load1; loadAfter = after.load1
        memoryBefore = before.memory; memoryAfter = after.memory
        thermalBefore = before.thermal; thermalAfter = after.thermal
        if !inventoryAvailable || !before.load1.isFinite || !after.load1.isFinite || before.load1 < 0 || after.load1 < 0 || !seconds.isFinite || seconds < 1 || seconds > 180 || target.memoryKB < 0
            || (afterTarget?.memoryKB ?? 0) < 0 || (afterTarget != nil && afterTarget?.id != target.id) {
            outcome = .unavailable
        } else if action == .quit {
            outcome = afterTarget == nil ? .stopped : .stillRunning
        } else if let current = afterTarget {
            let drop = target.memoryKB - current.memoryKB
            outcome = drop >= 32 * 1024 && Double(drop) >= Double(target.memoryKB) * 0.05 ? .memoryDecreased : .noClearDecrease
        } else {
            outcome = .notReopened
        }
    }

    public var summary: String {
        switch outcome {
        case .stopped: return tr("%1$@ has stopped.", program)
        case .stillRunning: return tr("%1$@ is still running; no improvement is confirmed.", program)
        case .notReopened: return tr("%1$@ has not reopened; this is not a successful restart.", program)
        case .memoryDecreased:
            return tr("%1$@ memory use decreased: %2$@ → %3$@.", program,
                      MemoryFormat.string(kibibytes: beforeMemoryKB), MemoryFormat.string(kibibytes: afterMemoryKB ?? 0))
        case .noClearDecrease: return tr("%1$@ reopened, but its memory use has not clearly decreased.", program)
        case .unavailable: return tr("The follow-up readings cannot be compared. Check again.")
        }
    }

    public var detail: String {
        guard outcome != .unavailable else { return tr("No performance improvement is claimed.") }
        return MachinePulse.sentences(
            tr("Memory pressure: %1$@ → %2$@. Thermal pressure: %3$@ → %4$@. One-minute load: %5$@ → %6$@.",
               MachinePulse.memoryName(memoryBefore), MachinePulse.memoryName(memoryAfter),
               MachinePulse.thermalName(thermalBefore), MachinePulse.thermalName(thermalAfter),
               String(format: "%.1f", loadBefore), String(format: "%.1f", loadAfter)),
            tr("This is a short follow-up; swap and load averages may take longer to change."))
    }

    public static func findTarget(_ target: MachinePulse.Hog, in inventory: [MachinePulse.Hog]) -> MachinePulse.Hog? {
        inventory.first { $0.id == target.id }
    }
}

extension PulseActionReview {
    /// Quits and restarts go into the shared operation history with what the follow-up reading saw.
    public func record(home: String = NSHomeDirectory()) {
        let ok: Set<Outcome> = [.stopped, .memoryDecreased, .noClearDecrease]
        OperationJournal.record(OperationRecord(feature: "pulse", action: action.rawValue, subject: program,
                                                items: [.init(target: program, status: ok.contains(outcome) ? "done" : outcome == .unavailable ? "partial" : "failed",
                                                              detail: outcome.rawValue)]), home: home)
    }
}
