import Foundation

/// Password-installed helpers own their launchd registration and update from --source.
/// SMAppService must never unregister that same label during an automatic upgrade.
@MainActor
final class HelperUpgradeCoordinator {
    private(set) var attempted = false
    nonisolated init() {}

    @discardableResult
    func restartManaged(legacyInstalled: Bool,
                        unregister: () async throws -> Void,
                        register: () throws -> Void) async throws -> Bool {
        guard !legacyInstalled, !attempted else { return false }
        attempted = true
        try await unregister()
        try register()
        return true
    }
}
