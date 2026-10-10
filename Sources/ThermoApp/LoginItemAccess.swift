import ServiceManagement
import SwiftUI
import ThermoL10n

@MainActor
final class LoginItemAccess: ObservableObject {
    static let shared = LoginItemAccess()
    enum State: Equatable { case unknown, off, enabled, needsApproval, unavailable }
    @Published private(set) var state: State = .unknown
    @Published private(set) var error: String?
    private let status: () -> SMAppService.Status
    private let register: () throws -> Void
    private let unregister: () throws -> Void

    init(status: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
         register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
         unregister: @escaping () throws -> Void = { try SMAppService.mainApp.unregister() }) {
        self.status = status
        self.register = register
        self.unregister = unregister
    }

    nonisolated static func state(_ status: SMAppService.Status) -> State {
        switch status {
        case .notRegistered: return .off
        case .enabled: return .enabled
        case .requiresApproval: return .needsApproval
        case .notFound: return .unavailable
        @unknown default: return .unknown
        }
    }

    var requested: Bool { state == .enabled || state == .needsApproval }

    func refresh() {
        state = Self.state(status())
        if state == .enabled { error = nil }
    }

    func setRequested(_ enabled: Bool) {
        refresh()
        guard enabled != requested else { return }
        error = nil
        do {
            if enabled { try register() } else { try unregister() }
        } catch {
            self.error = tr("Launch at login: %1$@", error.localizedDescription)
        }
        refresh()
    }

    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
