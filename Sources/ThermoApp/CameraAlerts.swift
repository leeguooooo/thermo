import AgentCore
import Combine
import Foundation
import ThermoL10n
import UserNotifications

@MainActor final class CameraAlerts: ObservableObject {
    static let shared = CameraAlerts()
    nonisolated static let enabledKey = "cameraActivityAlerts"
    nonisolated static let category = "thermo.camera"
    @Published private(set) var observation: CameraObservation?
    @Published private(set) var eventCoverage: Bool?
    @Published private(set) var deliveryError: String?
    private(set) var enabled = false
    private let defaults: UserDefaults
    private let read: @Sendable () async -> CameraObservation
    private let send: @MainActor (CameraDevice) -> Void
    private var generation = 0
    private var transitions = CameraTransitions()
    private var worker: Task<Void, Never>?
    private var pending = false
    private var timer: Timer?
    private var watcher: CameraActivity.Watcher?
    init(defaults: UserDefaults = .standard,
         read: @escaping @Sendable () async -> CameraObservation = { await Task.detached(priority: .utility) { CameraActivity.read() }.value },
         send: (@MainActor (CameraDevice) -> Void)? = nil) {
        self.defaults = defaults; self.read = read; self.send = send ?? { Self.notify($0) }
    }
    func start() { configure(defaults.bool(forKey: Self.enabledKey)) }
    func configure(_ on: Bool, schedule: Bool = true) {
        guard enabled != on else { return }
        enabled = on; generation += 1; observation = nil; transitions.reset(); pending = false
        eventCoverage = nil; deliveryError = nil
        timer?.invalidate(); timer = nil; watcher?.stop(); watcher = nil
        guard on else { return }
        if schedule {
            let epoch = generation
            watcher = CameraActivity.Watcher(changed: { [weak self] in Task { @MainActor in
                guard let self, self.enabled, self.generation == epoch else { return }; self.poll()
            } }, coverage: { [weak self] value in Task { @MainActor in
                guard let self, self.enabled, self.generation == epoch else { return }; self.eventCoverage = value
            } })
            watcher?.start()
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in Task { @MainActor in
                self?.watcher?.refresh(); self?.poll()
            } }
        }
        poll()
    }
    func poll() {
        guard enabled else { return }
        guard worker == nil else { pending = true; return }
        pending = false
        let epoch = generation, read = read
        worker = Task { [weak self] in
            let value = await read()
            guard let self else { return }
            self.worker = nil
            guard self.enabled else { return }
            guard epoch == self.generation else { self.poll(); return }
            self.observation = value
            for device in self.transitions.observe(value) { self.send(device) }
            if self.pending { self.poll() }
        }
    }
    func controlReport(notificationAccess: String) -> CameraReport {
        .init(observation: observation, source: "appObserver", enabled: enabled,
              eventCoverage: !enabled ? "disabled" : eventCoverage.map { $0 ? "registered" : "degraded" } ?? "checking",
              notificationAccess: notificationAccess, notificationIssue: deliveryError)
    }
    private static func notify(_ device: CameraDevice) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = tr("Camera activity detected")
        content.body = tr("%1$@ is active. The application using it is not identified.", device.name)
        content.categoryIdentifier = category
        // Hardware UID is used only in the in-memory transition detector, never persisted or exported.
        let request = UNNotificationRequest(identifier: "thermo.camera." + UUID().uuidString, content: content, trigger: nil)
        let epoch = shared.generation
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Task { @MainActor in
                guard shared.enabled, shared.generation == epoch else { return }
                shared.deliveryError = error.localizedDescription
            } }
        }
    }
}
