import AppKit
import SwiftUI
import UserNotifications
import ThermoL10n

/// Read the permission separately from the user's alert preferences.
@MainActor
final class NotificationAccess: ObservableObject {
    static let shared = NotificationAccess()

    enum State: Equatable { case unknown, unavailable, notRequested, denied, allowed, bannersDisabled }
    @Published private(set) var state: State = .unknown
    @Published private(set) var requesting = false
    @Published private(set) var error: String?
    private var revision = 0

    nonisolated static func state(status: UNAuthorizationStatus, alerts: UNNotificationSetting) -> State {
        switch status {
        case .notDetermined: return .notRequested
        case .denied: return .denied
        case .authorized:
            return alerts == .disabled ? .bannersDisabled : .allowed
        case .provisional: return .bannersDisabled
        @unknown default: return .unknown
        }
    }

    func refresh() {
        guard Bundle.main.bundleIdentifier != nil else { state = .unavailable; return }
        revision += 1
        let revision = revision
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let state = Self.state(status: settings.authorizationStatus, alerts: settings.alertSetting)
            Task { @MainActor in
                guard self.revision == revision else { return }
                self.state = state
                if state == .allowed || state == .bannersDisabled { self.error = nil }
            }
        }
    }

    /// A control reply must await its own query, rather than assume refresh finished after a delay.
    func readCurrentState() async -> State {
        guard Bundle.main.bundleIdentifier != nil else { return .unavailable }
        return await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: Self.state(status: settings.authorizationStatus, alerts: settings.alertSetting))
            }
        }
    }

    func request() {
        guard !requesting else { return }
        guard Bundle.main.bundleIdentifier != nil else { state = .unavailable; return }
        requesting = true
        revision += 1
        error = nil
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            Task { @MainActor in
                self.requesting = false
                self.error = error?.localizedDescription
                self.refresh()
            }
        }
    }

    func openSettings() {
        if !NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!),
           let settings = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
            NSWorkspace.shared.open(settings)
        }
    }
}
