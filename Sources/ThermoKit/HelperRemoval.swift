import Foundation

/// Owned by the helper's serial control queue. Failed preparation remains fenced
/// until the caller cancels; clearing the fence never restores old manual policies.
public final class HelperRemovalGuard {
    private var activeToken: String?
    public var isPreparing: Bool { activeToken != nil }
    public init() {}

    public func prepare(token: String, clearPolicies: () -> Void, savePolicies: () throws -> Void,
                        restoreFans: () -> FanAutoRecoveryReport,
                        restoreSleep: () throws -> Void = {}) throws {
        guard !token.isEmpty, activeToken == nil || activeToken == token else {
            throw FanControlError.helper("another helper removal is already in progress")
        }
        activeToken = token
        clearPolicies()
        var failures: [String] = []
        do { try savePolicies() } catch { failures.append("could not save automatic policies: \(error)") }
        let report = restoreFans()
        if !report.confirmed { failures.append(report.summary) }
        do { try restoreSleep() } catch { failures.append("could not restore sleep setting: \(error)") }
        if !failures.isEmpty { throw FanControlError.helper(failures.joined(separator: "; ")) }
    }

    public func cancel(token: String) throws {
        guard activeToken == nil || activeToken == token else {
            throw FanControlError.helper("another helper removal owns the preparation")
        }
        activeToken = nil
    }
    public func abandon(ownerPrefix: String) {
        if !ownerPrefix.isEmpty,activeToken?.hasPrefix(ownerPrefix) == true { activeToken=nil }
    }
}

/// Shared by CLI and App; every side effect is injectable without root or XPC.
public enum HelperRemovalOperation {
    public static func run(prepare: () throws -> Void, remove: () throws -> Void,
                           cancel: () throws -> Void) throws {
        do {
            try prepare()
            try remove()
        } catch {
            let original = error
            do { try cancel() } catch {
                throw FanControlError.helper("\(original); could not release removal preparation: \(error)")
            }
            throw original
        }
    }
}
