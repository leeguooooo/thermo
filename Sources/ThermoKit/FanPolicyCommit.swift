import Foundation

/// A manual request must be saved before it can affect control. An automatic
/// request must still release control even when its persistence fails.
public enum FanPolicyCommit {
    public static func apply(_ policy: FanPolicy, save: () throws -> Void, commit: () -> Void,
                             applyAutomatic: () throws -> Void,
                             restoreAll: () -> FanAutoRecoveryReport,
                             recordFault: (String) -> Void) throws {
        try policy.validate()
        if policy != .auto {
            do { try save() } catch {
                throw FanControlError.helper("fan policy was not saved; request was not applied: \(error)")
            }
            commit()
            return
        }

        commit()
        var persistenceError: String?
        do { try save() } catch { persistenceError = "automatic policy was not saved; previous policies may return after restart: \(error)" }
        var hardwareError: String?
        do { try applyAutomatic() } catch { hardwareError = String(describing: error) }
        if persistenceError != nil || hardwareError != nil {
            let recovery = restoreAll()
            var failures = [persistenceError].compactMap { $0 }
            if !recovery.confirmed {
                if let hardwareError { failures.append(hardwareError) }
                failures.append(recovery.summary)
            }
            if !failures.isEmpty {
                let message = failures.joined(separator: "; ")
                recordFault(message)
                throw FanControlError.helper(message)
            }
        }
    }
}
