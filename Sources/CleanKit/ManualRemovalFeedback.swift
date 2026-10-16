import Foundation
import ThermoL10n

extension ManualRemoval {
    /// Report confirmed moves separately from retained paths and post-move bookkeeping failures.
    public static func feedback(_ result: CleanResult) -> [String] {
        var lines = [result.removed.isEmpty
            ? tr("Nothing was moved to the Trash.")
            : tr("Moved %1$@ to the Trash (%2$@).", trCount(result.removed.count, "%1$@ item", "%1$@ items"),
                 AppSize.text(result.bytes, state: result.bytesIncomplete == true ? .incomplete : .complete))]
        let moved = Set(result.removed)
        let notMoved = result.failed.filter { $0.key.hasPrefix("/") && !moved.contains($0.key) }
        if !notMoved.isEmpty {
            lines.append(tr("Not moved: %1$@", notMoved.sorted { $0.key < $1.key }
                .map { FS.tilde($0.key) + " (" + $0.value + ")" }.joined(separator: "; ")))
        }
        if let kept = result.whitelisted, !kept.isEmpty {
            lines.append(tr("Kept by the whitelist: %1$@", Set(kept).sorted().map { FS.tilde($0) }.joined(separator: "; ")))
        }
        for (key, reason) in result.failed.sorted(by: { $0.key < $1.key }) where notMoved[key] == nil {
            if key.hasPrefix("batch/") {
                lines.append(tr("Recovery record issue: %1$@", reason))
            } else {
                lines.append(reason)
            }
        }
        return lines
    }
}
