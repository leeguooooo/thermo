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
    static let unnamedSensors = "unnamedSensors"
    /// Show the Dock icon (on by default: a menu bar icon alone is easy to lose, e.g. behind the notch).
    static let showInDock = "showInDock"

    static func register() {
        UserDefaults.standard.register(defaults: [
            showInDock: true,
            PulseRecorder.alertsKey: true,
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
    @Published private(set) var policiesAvailable = false
    @Published private(set) var applyingPolicies = false
    @Published private(set) var installingHelper = false
    @Published private(set) var uninstallingHelper = false
    var helperBusy: Bool { applyingPolicies || installingHelper || uninstallingHelper }
    private var policyRevision = 0
    private var lastHelperRefresh = Date.distantPast
    @Published var lastError: String?
    @Published private(set) var model = ""
    /// The menu bar icon is hidden (behind the notch or pushed off by other icons).
    @Published var iconHidden = false

    /// Called on the main thread after each sample (menu bar title).
    var onUpdate: ((Snapshot) -> Void)?

    /// Published copy of `watched` (panel or main window open) for views that must stop work when the panel closes: the popover's
    /// SwiftUI views stay alive (no onDisappear) while it is closed.
    @Published private(set) var panelVisible = false

    var popoverOpen = false { didSet { if popoverOpen != oldValue { visibilityChanged() } } }
    /// The main window is on screen: it shows the same live data as the panel.
    var windowOpen = false { didSet { if windowOpen != oldValue { visibilityChanged() } } }
    /// Someone is looking: full sampling at the chosen rate.
    var watched: Bool { popoverOpen || windowOpen }

    private func visibilityChanged() {
        let open = watched
        guard open != panelVisible else { return }
        panelVisible = open
        queue.async { self.fullSampling = open }
        if open {
            // SwiftUI only sees data while visible; hand over what accumulated meanwhile.
            history = buffer
            if let latest { snapshot = latest }
        }
        reschedule()
        if open { sampleNow(); refreshHelper() }
    }

    static let historyWindow: TimeInterval = 600

    private let queue = DispatchQueue(label: "dev.thermo.app.sampler", qos: .utility)
    private var sampler: Sampler?
    /// Mirror of `popoverOpen`, confined to `queue`.
    private var fullSampling = false
    private var includeUnnamed = false

    func showUnnamedSensors(_ enabled: Bool) {
        queue.async { [weak self] in
            self?.includeUnnamed = enabled
            self?.sample()
        }
    }
    private var timer: DispatchSourceTimer?
    private var lastAlert = Date.distantPast
    /// Background data, kept out of @Published so hidden SwiftUI views don't re-render.
    private var buffer: [HistoryPoint] = []
    private(set) var latest: Snapshot?
    private let helper = HelperClient()

    init(startMonitoring: Bool = true) {
        guard startMonitoring else { return }
        queue.async { [weak self] in self?.prepareSampler() }
        reschedule()
        refreshHelper()
    }

    var interval: TimeInterval { max(0.5, UserDefaults.standard.double(forKey: Settings.interval)) }

    func reschedule() {
        timer?.cancel()
        // Background: essential sensors only, at least every 2 s. Popover open: everything at the chosen rate.
        let every = watched ? interval : max(interval, 2)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: every, leeway: .milliseconds(Int(every * 100)))
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        timer = t
    }

    /// Retry initialization too: a temporary SMC failure must not leave the app stuck loading.
    func sampleNow() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.sampler == nil { self.prepareSampler() }
            self.sample()
        }
    }

    private func prepareSampler() {
        do {
            let s = try Sampler(scope: .essential)
            sampler = s
            DispatchQueue.main.async { [weak self] in
                self?.model = s.discovery.model
                self?.lastError = nil
            }
        } catch {
            DispatchQueue.main.async { [weak self] in self?.lastError = "\(error)" }
        }
    }

    private func sample() {
        guard let sampler else { return }
        let open = fullSampling
        let defaults = UserDefaults.standard
        let metric = TitleMetric(rawValue: defaults.string(forKey: Settings.titleMetric) ?? "") ?? .cpu
        let plan = SamplingPlan.make(visible: open, includeUnnamed: includeUnnamed, metric: metric,
                                     alerts: defaults.bool(forKey: Settings.alertsEnabled))
        sampler.scope = plan.scope
        sampler.parts = plan.parts
        sampler.groups = plan.groups
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
            if self.watched {
                self.snapshot = s
                self.history = self.buffer
                if Date().timeIntervalSince(self.lastHelperRefresh) >= 10 { self.refreshHelper() }
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
        let fahrenheit = d.bool(forKey: Settings.fahrenheit)
        content.body = tr(fahrenheit ? "Hottest sensor at %1$@ °F" : "Hottest sensor at %1$@ °C", String(format: "%.0f", fahrenheit ? hot * 9 / 5 + 32 : hot))
            + (s.fans.first.map { tr(", fans at %1$@ rpm", String(format: "%.0f", $0.rpm)) } ?? "")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "thermo.hot", content: content, trigger: nil))
    }

    static func requestNotificationPermission() {
        Task { @MainActor in NotificationAccess.shared.request() }
    }

    // MARK: Helper / fan control

    /// Developer ID builds register the bundled daemon with SMAppService (user approves it in
    /// System Settings → Login Items). Ad-hoc builds install it with an administrator prompt.
    let usesSMAppService = CodeSignature.teamIdentifier() != nil
    private let daemon = SMAppService.daemon(plistName: HelperConstants.bundledPlistName)

    /// Fan settings chosen before the helper could take them; applied as soon as it answers.
    @Published private(set) var pendingPolicies: [Int: FanPolicy] = [:]
    /// Set while the user is being walked through allowing the helper.
    @Published private(set) var settingUp = false
    @Published private(set) var setupStarted: Date?
    private var setupTimer: Timer?
    private var refreshingHelper = false

    func refreshHelper() {
        guard !refreshingHelper, !helperBusy else { return }
        refreshingHelper = true
        lastHelperRefresh = Date()
        let revision = policyRevision
        Task { @MainActor in
            defer { refreshingHelper = false }
            // Whatever answers is running, however it was installed (Login Items or password).
            if let v = try? await helper.version() {
                let active = try? await helper.policies()
                guard revision == policyRevision, !helperBusy else { return }
                policiesAvailable = active != nil
                if let active { policies = active }
                helperState = v == HelperConstants.version ? .running : .outdated
                if helperState == .outdated { restartOutdatedHelper() }
                finishSetup()
                return
            }
            guard revision == policyRevision, !helperBusy else { return }
            policiesAvailable = false
            if usesSMAppService {
                switch daemon.status {
                case .requiresApproval:
                    helperState = .needsApproval
                case .enabled:
                    // Registered, but launchd will not start it: background items for this app or
                    // developer are off in Login Items. Reinstalling cannot fix that; approving can.
                    let refused = await Task.detached { Self.launchdRefusesHelper() }.value
                    guard revision == policyRevision, !helperBusy else { return }
                    helperState = refused ? .needsApproval : .notRunning
                default:
                    helperState = HelperInstaller.isInstalled ? .notRunning : .notInstalled
                }
            } else {
                helperState = HelperInstaller.isInstalled ? .notRunning : .notInstalled
            }
        }
    }

    /// Starts setup the way a person expects: one administrator password prompt, done. A helper
    /// that already answers is kept, and one already approved under Login Items is left to
    /// launchd; nobody is sent hunting through System Settings.
    func beginSetup() {
        guard !settingUp, !helperBusy else { return }
        settingUp = true
        setupStarted = Date()
        Task { @MainActor in
            if (try? await helper.version()) != nil { refreshHelper(); return }
            if usesSMAppService, daemon.status == .enabled,
               !(await Task.detached { Self.launchdRefusesHelper() }.value) {
                watchSetup()   // approved earlier; launchd is starting it
                return
            }
            installHelperWithPassword()
        }
    }

    /// Polls once a second while the user is in System Settings; stops when the helper answers
    /// or after ten minutes.
    private func watchSetup() {
        setupTimer?.invalidate()
        setupTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if let start = self.setupStarted, Date().timeIntervalSince(start) > 600 {
                self.stopSetup()
                self.lastError = tr("The fan helper did not respond. Your settings have not been applied. Retry setup when ready.")
                return
            }
            self.refreshHelper()
        }
    }

    func stopSetup() {
        setupTimer?.invalidate()
        setupTimer = nil
        settingUp = false
        setupStarted = nil
    }

    private func finishSetup() {
        guard !helperBusy else { return }
        guard [.running, .outdated].contains(helperState) else { stopSetup(); return }
        stopSetup()
        let pending = pendingPolicies
        pendingPolicies = [:]
        if !pending.isEmpty { applyPolicies(pending.sorted(by: { $0.key < $1.key }).map { ($0.key, $0.value) }) }
    }

    /// The fallback that always works: one administrator prompt installs the helper as a
    /// classic launch daemon (used when Login Items approval is stuck or not available).
    func installHelperWithPassword() {
        guard !helperBusy else { return }
        guard let bin = HelperInstaller.locateHelperBinary() else {
            lastError = tr("thermo-helper not found inside the app bundle")
            stopSetup()
            return
        }
        settingUp = true
        installingHelper = true
        policyRevision += 1
        setupStarted = setupStarted ?? Date()
        DispatchQueue.global(qos: .userInitiated).async {
            // The Login Items registration would claim the same launchd label.
            if self.usesSMAppService, self.daemon.status != .notRegistered { try? self.daemon.unregister() }
            do {
                try HelperInstaller.install(from: bin)
                // The old connection pointed at the job that was just replaced.
                self.helper.reset()
                DispatchQueue.main.async {
                    self.installingHelper = false
                    self.lastError = nil
                    self.watchSetup()
                }
            } catch {
                DispatchQueue.main.async {
                    self.installingHelper = false
                    self.lastError = "\(error)".contains("cancelled") ? nil : "\(error)"
                    self.stopSetup()
                }
            }
        }
    }

    /// `launchctl print` (no privileges needed) shows a spawn that launchd refuses as exit 78
    /// (EX_CONFIG) — what happens when the user turned Thermo off under "Allow in the Background".
    nonisolated static func launchdRefusesHelper() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["print", "system/\(HelperConstants.label)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return text.contains("last exit code = 78") || text.contains("job state = spawn failed")
    }

    private var restartedOutdatedHelper = false

    /// Helpers before 1.0.2 don't restart themselves when the app is updated, so
    /// after an update they keep running the old binary until a reboot. For the
    /// SMAppService daemon, unregister + register makes launchd start the new one
    /// (the old helper returns the fans to auto on SIGTERM). Once per launch.
    private func restartOutdatedHelper() {
        guard usesSMAppService, daemon.status == .enabled, !restartedOutdatedHelper, !helperBusy else { return }
        restartedOutdatedHelper = true
        installingHelper = true
        policyRevision += 1
        Task { @MainActor in
            do {
                try await daemon.unregister()
                try daemon.register()
            } catch {
                lastError = tr("Helper update: %1$@", error.localizedDescription)
            }
            if daemon.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            installingHelper = false
            refreshHelper()
        }
    }

    func setPolicy(_ policy: FanPolicy, fan: Int) {
        guard !helperBusy else { return }
        do { try policy.validate() } catch { lastError = "\(error)"; return }
        guard [.running, .outdated].contains(helperState) else {
            pendingPolicies[fan] = policy
            if !settingUp { beginSetup() }
            return
        }
        applyPolicies([(fan, policy)])
    }

    private func applyPolicies(_ changes: [(Int, FanPolicy)]) {
        guard !helperBusy else { return }
        applyingPolicies = true
        policyRevision += 1
        Task { @MainActor in
            let result = await FanPolicyOperation.run(changes,
                set: { try await self.helper.setPolicy($0, fan: $1) },
                read: { try await self.helper.policies() })
            if let active = result.policies { policies = active }
            policiesAvailable = result.policies != nil
            lastError = result.error
            applyingPolicies = false
            sampleNow()
            if result.policies == nil { refreshHelper() }
        }
    }

    /// "Install…" / "Reinstall…" / "Update…" buttons and `--install-helper`.
    func installHelper() { beginSetup() }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    func uninstallHelper() {
        uninstallHelper(operation: {
            if self.usesSMAppService && self.daemon.status != .notRegistered {
                try self.daemon.unregister()
            }
            if HelperInstaller.isInstalled { try HelperInstaller.uninstall() }
        })
    }

    /// The injected operation keeps regression checks away from the real root helper.
    func uninstallHelper(operation: @escaping () throws -> Void, finished: @escaping () -> Void = {}) {
        guard !helperBusy, !settingUp else { return }
        uninstallingHelper = true
        policyRevision += 1
        policiesAvailable = false
        stopSetup()
        pendingPolicies = [:]
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do { try operation() } catch { failure = "\(error)" }
            let error = failure
            DispatchQueue.main.async {
                self.uninstallingHelper = false
                self.lastError = error
                self.helper.reset()
                if error == nil { self.policies = [:] }
                self.refreshHelper()
                finished()
            }
        }
    }

}
