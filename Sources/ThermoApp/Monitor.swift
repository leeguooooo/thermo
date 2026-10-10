import Foundation
import ServiceManagement
import ThermoKit
import ThermoL10n
import UserNotifications

enum TitleMetric: String, CaseIterable, Identifiable {
    case cpu, hottest, fan, cpuAndFan, power, iconOnly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .cpu: return tr("CPU temperature")
        case .hottest: return tr("Hottest sensor")
        case .fan: return tr("Fan speed")
        case .cpuAndFan: return tr("CPU temperature + fan")
        case .power: return tr("System power")
        case .iconOnly: return tr("Icon only")
        }
    }
}

enum HelperState: Equatable {
    case unknown, notInstalled, needsApproval, notRunning, outdated, running
}

struct HistoryPoint: Identifiable {
    let time: Date
    let cpu: Double?
    let gpu: Double?
    let fans: [Double]
    let power: Double?
    var id: Date { time }
}

enum Settings {
    static let interval = "interval"
    static let titleMetric = "titleMetric"
    static let alertsEnabled = "alertsEnabled"
    static let alertThreshold = "alertThreshold"
    static let fahrenheit = "fahrenheit"
    /// Show the Dock icon (on by default: a menu bar icon alone is easy to lose, e.g. behind the notch).
    static let showInDock = "showInDock"

    static func register() {
        UserDefaults.standard.register(defaults: [
            showInDock: true,
            interval: 2.0, titleMetric: TitleMetric.cpu.rawValue,
            alertsEnabled: false, alertThreshold: 90.0, fahrenheit: false,
        ])
    }
}

/// Owns the sampler on a background queue and publishes snapshots on the main thread.
final class Monitor: ObservableObject {
    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var history: [HistoryPoint] = []
    @Published private(set) var helperState: HelperState = .unknown
    @Published private(set) var policies: [Int: FanPolicy] = [:]
    @Published var lastError: String?
    @Published private(set) var model = ""
    /// The menu bar icon is hidden (behind the notch or pushed off by other icons).
    @Published var iconHidden = false

    /// Called on the main thread after each sample (menu bar title).
    var onUpdate: ((Snapshot) -> Void)?

    var popoverOpen = false {
        didSet {
            guard popoverOpen != oldValue else { return }
            let open = popoverOpen
            queue.async { self.fullSampling = open }
            if open {
                // SwiftUI only sees data while visible; hand over what accumulated meanwhile.
                history = buffer
                if let latest { snapshot = latest }
            }
            reschedule()
            if open { sampleNow() }
        }
    }

    static let historyWindow: TimeInterval = 600

    private let queue = DispatchQueue(label: "dev.thermo.app.sampler", qos: .utility)
    private var sampler: Sampler?
    /// Mirror of `popoverOpen`, confined to `queue`.
    private var fullSampling = false
    private var timer: DispatchSourceTimer?
    private var lastAlert = Date.distantPast
    /// Background data, kept out of @Published so hidden SwiftUI views don't re-render.
    private var buffer: [HistoryPoint] = []
    private(set) var latest: Snapshot?
    private let helper = HelperClient()

    init() {
        queue.async { [weak self] in
            do {
                let s = try Sampler(scope: .essential)
                DispatchQueue.main.async { self?.model = s.discovery.model }
                self?.sampler = s
            } catch {
                DispatchQueue.main.async { self?.lastError = "\(error)" }
            }
        }
        reschedule()
        refreshHelper()
    }

    var interval: TimeInterval { max(0.5, UserDefaults.standard.double(forKey: Settings.interval)) }

    func reschedule() {
        timer?.cancel()
        // Background: essential sensors only, at least every 2 s. Popover open: everything at the chosen rate.
        let every = popoverOpen ? interval : max(interval, 2)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: every, leeway: .milliseconds(Int(every * 100)))
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        timer = t
    }

    func sampleNow() { queue.async { [weak self] in self?.sample() } }

    private func sample() {
        guard let sampler else { return }
        let open = fullSampling
        sampler.scope = open ? .known : .essential
        if open {
            sampler.parts = .everything
            sampler.groups = nil
        } else {
            // Background: only what the menu bar title, alerts and history need.
            let metric = TitleMetric(rawValue: UserDefaults.standard.string(forKey: Settings.titleMetric) ?? "") ?? .cpu
            sampler.parts = metric == .power ? [.temperatures, .fans, .power] : [.temperatures, .fans]
            sampler.groups = [.cpu, .gpu]
        }
        let s = sampler.sample()
        let point = HistoryPoint(time: s.timestamp, cpu: s.cpu, gpu: s.gpu, fans: s.fans.map(\.rpm), power: s.systemPower)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.latest = s
            self.buffer.append(point)
            let cutoff = Date().addingTimeInterval(-Self.historyWindow)
            if let first = self.buffer.firstIndex(where: { $0.time >= cutoff }), first > 0 {
                self.buffer.removeFirst(first)
            }
            if self.popoverOpen {
                self.snapshot = s
                self.history = self.buffer
            }
            self.onUpdate?(s)
            self.checkAlert(s)
        }
    }

    // MARK: Alerts

    private func checkAlert(_ s: Snapshot) {
        let d = UserDefaults.standard
        // UserNotifications throws (and kills the app) outside an app bundle, e.g. a bare dev build.
        guard Bundle.main.bundleIdentifier != nil else { return }
        guard d.bool(forKey: Settings.alertsEnabled), let hot = s.hottest,
              hot >= d.double(forKey: Settings.alertThreshold),
              Date().timeIntervalSince(lastAlert) > 300 else { return }
        lastAlert = Date()
        let content = UNMutableNotificationContent()
        content.title = tr("Mac is running hot")
        content.body = tr("Hottest sensor at %1$@ °C", String(format: "%.0f", hot))
            + (s.fans.first.map { tr(", fans at %1$@ rpm", String(format: "%.0f", $0.rpm)) } ?? "")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "thermo.hot", content: content, trigger: nil))
    }

    static func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: Helper / fan control

    /// Developer ID builds register the bundled daemon with SMAppService (user approves it in
    /// System Settings → Login Items). Ad-hoc builds install it with an administrator prompt.
    let usesSMAppService = CodeSignature.teamIdentifier() != nil
    private let daemon = SMAppService.daemon(plistName: HelperConstants.bundledPlistName)

    func refreshHelper() {
        if usesSMAppService {
            switch daemon.status {
            case .requiresApproval: helperState = .needsApproval; return
            case .enabled: break
            default:
                if !HelperInstaller.isInstalled { helperState = .notInstalled; return }
            }
        } else if !HelperInstaller.isInstalled {
            helperState = .notInstalled
            return
        }
        Task { @MainActor in
            do {
                let v = try await helper.version()
                policies = try await helper.policies()
                helperState = v == HelperConstants.version ? .running : .outdated
                if helperState == .outdated { restartOutdatedHelper() }
            } catch {
                helperState = .notRunning
            }
        }
    }

    private var restartedOutdatedHelper = false

    /// Helpers before 1.0.2 don't restart themselves when the app is updated, so
    /// after an update they keep running the old binary until a reboot. For the
    /// SMAppService daemon, unregister + register makes launchd start the new one
    /// (the old helper returns the fans to auto on SIGTERM). Once per launch.
    private func restartOutdatedHelper() {
        guard usesSMAppService, daemon.status == .enabled, !restartedOutdatedHelper else { return }
        restartedOutdatedHelper = true
        Task { @MainActor in
            do {
                try await daemon.unregister()
                try daemon.register()
            } catch {
                lastError = "Helper update: \(error.localizedDescription)"
            }
            if daemon.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            refreshHelper()
        }
    }

    func setPolicy(_ policy: FanPolicy, fan: Int) {
        Task { @MainActor in
            do {
                try await helper.setPolicy(policy, fan: fan)
                policies = try await helper.policies()
                lastError = nil
                sampleNow()
            } catch {
                lastError = "\(error)"
                refreshHelper()
            }
        }
    }

    func installHelper() {
        if usesSMAppService {
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    // A legacy (admin-prompt) install would own the same launchd label.
                    if HelperInstaller.isInstalled { try HelperInstaller.uninstall() }
                    try self.daemon.register()
                } catch {
                    DispatchQueue.main.async { self.lastError = tr("Helper registration: %1$@", error.localizedDescription) }
                }
                DispatchQueue.main.async {
                    if self.daemon.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refreshHelper() }
                }
            }
            return
        }
        guard let bin = HelperInstaller.locateHelperBinary() else {
            lastError = tr("thermo-helper not found inside the app bundle")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try HelperInstaller.install(from: bin)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refreshHelper() }
            } catch {
                DispatchQueue.main.async { self.lastError = "\(error)" }
            }
        }
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    func uninstallHelper() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if self.usesSMAppService && self.daemon.status != .notRegistered {
                    try self.daemon.unregister()
                }
                if HelperInstaller.isInstalled { try HelperInstaller.uninstall() }
                DispatchQueue.main.async { self.policies = [:]; self.refreshHelper() }
            } catch {
                DispatchQueue.main.async { self.lastError = "\(error)" }
            }
        }
    }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                lastError = tr("Launch at login: %1$@", error.localizedDescription)
            }
            objectWillChange.send()
        }
    }
}
