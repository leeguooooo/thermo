import AgentCore
import AppKit
import Foundation
import ThermoL10n
import UserNotifications

/// Five-second metadata polls only while enabled. An old physical read must finish before another starts.
@MainActor
final class MicrophoneAlerts: ObservableObject {
    static let shared = MicrophoneAlerts()
    nonisolated static let enabledKey = "audioInputAlerts"
    nonisolated static let mutedKey = "audioInputMutedApplications"
    nonisolated static let mutedNamesKey = "audioInputMutedNames"
    nonisolated static let category = "thermo.audio-input"
    nonisolated static let muteAction = "thermo.audio-input.mute"

    @Published private(set) var observation: AudioInputObservation?
    @Published private(set) var muted: Set<String>
    @Published private(set) var knownApps: [String: String] = [:]
    @Published private(set) var deliveryError: String?
    @Published private(set) var eventCoverage: Bool?
    private let defaults: UserDefaults
    private let read: @Sendable () async -> AudioInputObservation
    private let send: @MainActor (AudioInputClient) -> Void
    private var transitions = AudioInputTransitions()
    private var timer: Timer?
    private var worker: Task<Void, Never>?
    private var watcher: AudioInputActivity.Watcher?
    private var generation = 0
    private var pollPending = false
    private(set) var enabled = false

    init(defaults: UserDefaults = .standard,
         read: @escaping @Sendable () async -> AudioInputObservation = { await Task.detached(priority: .utility) { AudioInputActivity.read() }.value },
         send: (@MainActor (AudioInputClient) -> Void)? = nil) {
        self.defaults = defaults; self.read = read
        self.send = send ?? { client in Self.notify(client) }
        let savedMuted = Set(defaults.stringArray(forKey: Self.mutedKey) ?? [])
        self.muted = savedMuted
        self.knownApps = (defaults.dictionary(forKey: Self.mutedNamesKey) as? [String: String] ?? [:]).filter { savedMuted.contains($0.key) }
    }

    func start() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationCategories { categories in
            let mute = UNNotificationAction(identifier: Self.muteAction, title: tr("Stop alerting for this app"), options: [])
            let category = UNNotificationCategory(identifier: Self.category, actions: [mute], intentIdentifiers: [], options: [])
            UNUserNotificationCenter.current().setNotificationCategories(Set(categories.filter { $0.identifier != Self.category }).union([category]))
        }
        configure(defaults.bool(forKey: Self.enabledKey))
    }

    func configure(_ on: Bool, schedule: Bool = true) {
        guard on != enabled else { return }
        enabled = on; generation += 1; transitions.reset(); observation = nil; deliveryError = nil; eventCoverage = nil; pollPending = false
        timer?.invalidate(); timer = nil
        watcher?.stop(); watcher = nil
        guard on else { return }
        if schedule {
            let epoch = generation
            watcher = AudioInputActivity.Watcher(changed: { [weak self] in
                Task { @MainActor in self?.poll() }
            }, coverage: { [weak self] complete in
                Task { @MainActor in
                    guard let self, self.enabled, self.generation == epoch else { return }
                    self.eventCoverage = complete
                }
            })
            watcher?.start()
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.watcher?.refresh()
                    self?.poll()
                }
            }
        }
        poll()
    }

    func poll() {
        guard enabled else { return }
        guard worker == nil else { pollPending = true; return }
        pollPending = false
        let epoch = generation, read = read
        worker = Task { [weak self] in
            let value = await read()
            guard let self else { return }
            self.worker = nil
            guard self.enabled else { return }
            guard self.generation == epoch else { self.poll(); return }
            self.observation = value
            for client in value.clients { self.knownApps[client.muteKey] = client.name }
            // Persist only explicit mutes. A process list is not a durable activity log.
            if self.knownApps.count > 256 {
                self.knownApps = self.knownApps.filter { key, _ in self.muted.contains(key) || value.clients.contains { $0.muteKey == key } }
            }
            for client in self.transitions.observe(value, muted: self.muted) { self.send(client) }
            if self.pollPending { self.poll() }
        }
    }

    func controlReport(notificationAccess: String) -> AudioInputReport {
        let labels = Dictionary(uniqueKeysWithValues: muted.map { ($0, knownApps[$0] ?? $0) })
        let coverage = !enabled ? "disabled" : eventCoverage.map { $0 ? "registered" : "degraded" } ?? "checking"
        return AudioInputReport(observation: observation, source: "appObserver", enabled: enabled,
            reading: worker != nil, eventCoverage: coverage, notificationAccess: notificationAccess,
            muted: labels, notificationIssue: deliveryError, limit: 64, byteBudget: 32_768)
    }

    func setMuted(_ key: String, _ value: Bool) {
        // Notification actions can arrive after restart; a stored mute may always be removed.
        guard !key.isEmpty, key.utf8.count <= 4096,
              knownApps[key] != nil || muted.contains(key) else { return }
        if value { muted.insert(key) } else { muted.remove(key) }
        defaults.set(muted.sorted(), forKey: Self.mutedKey)
        defaults.set(knownApps.filter { muted.contains($0.key) }, forKey: Self.mutedNamesKey)
    }

    func muteFromNotification(key: String, name: String) {
        guard !key.isEmpty, key.utf8.count <= 4096, !name.isEmpty, name.utf8.count <= 255,
              !name.contains(where: { $0.isNewline }) else { return }
        knownApps[key] = name
        setMuted(key, true)
    }

    private static func notify(_ client: AudioInputClient) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = tr("%1$@ started using audio input", client.name)
        content.body = client.devices.map(\.name).joined(separator: ", ")
        content.categoryIdentifier = category
        content.userInfo = ["audioInputApp": client.muteKey, "audioInputName": client.name]
        let request = UNNotificationRequest(identifier: "thermo.audio-input." + UUID().uuidString, content: content, trigger: nil)
        let epoch = shared.generation
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Task { @MainActor in
                if shared.enabled && shared.generation == epoch { shared.deliveryError = error.localizedDescription }
            } }
        }
    }
}
