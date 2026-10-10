import ThermoKit

/// Send each policy in order, then read back what the helper actually holds, even after a failed write.
enum FanPolicyOperation {
    struct Outcome {
        var policies: [Int: FanPolicy]?
        var error: String?
    }

    static func run(_ changes: [(Int, FanPolicy)],
                    set: (FanPolicy, Int) async throws -> Void,
                    read: () async throws -> [Int: FanPolicy]) async -> Outcome {
        var errors: [String] = []
        for (fan, policy) in changes {
            do { try await set(policy, fan) } catch { errors.append(String(describing: error)) }
        }
        do {
            return Outcome(policies: try await read(), error: errors.isEmpty ? nil : errors.joined(separator: "\n"))
        } catch {
            errors.append(String(describing: error))
            return Outcome(policies: nil, error: errors.joined(separator: "\n"))
        }
    }
}
