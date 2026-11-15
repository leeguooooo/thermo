import NativeFeatureAPI
import SystemServicesAPI
import ThermoUI
import AppKit
import Charts
import CleanKit
import SwiftUI
import ThermoKit
import ThermoL10n
import UserNotifications
import ModuleKit

/// Records the pulse in the background — once a minute on power, every five minutes on battery,
/// panel open or not — so a slowdown can be looked at afterwards, and tells the user about one
/// before they feel it. One cheap incremental pass per tick (PulseSampler).
final class PulseRecorder: ObservableObject {
    static let shared = PulseRecorder(samplingAllowed: { ModulePreferences.isEnabled(BuiltinModuleManifests.performance, in: .standard) })
    static let alertsKey = Settings.slowdownAlerts
    /// Posted (on main) when a slowdown notification is clicked; userInfo["program"] is who to show.
    static let showProgram = Notification.Name("dev.thermo.showPulseProgram")

    let history = PulseHistory()
    /// Each program's memory every five minutes, for telling a leak from a big program.
    let programHistory = ProgramMemoryHistory()
    private var lastProgramRecord = Date.distantPast
    /// The last six hours, for the Overview chart (oldest first).
    @Published private(set) var recent: [PulseRecord] = []
    /// A program to point at in the Overview after a notification was clicked.
    @Published var highlighted: String?
    /// The latest "why is it slow" answer, refreshed every tick (and on request).
    @Published private(set) var diagnosis: SlowdownDiagnosis?

    private let queue: DispatchQueue
    private let lifetime = FeatureSamplingLifetime()
    private let readHistory: (@Sendable () -> [PulseRecord])?
    private let readDiagnosis: (@Sendable () -> (SlowdownDiagnosis, [SlowdownProcess]))?
    private let samplingAllowed: @Sendable () -> Bool
    private let sampler = PulseSampler()
    /// Confined to `queue`; its previous pass turns CPU and disk counters into rates and busy streaks.
    private let slowdown = SlowdownSampler()
    private var alerts = SlowdownAlerts()
    private var timer: DispatchSourceTimer?
    private var interval: TimeInterval = 0
    private var memory: [PulseRecord] = []

    init(queue: DispatchQueue? = nil, readHistory: (@Sendable () -> [PulseRecord])? = nil,
         samplingAllowed: @escaping @Sendable () -> Bool = { true },
         readDiagnosis: (@Sendable () -> (SlowdownDiagnosis, [SlowdownProcess]))? = nil) {
        self.queue = queue ?? DispatchQueue(label: "dev.thermo.app.pulse-history", qos: .utility)
        self.readHistory = readHistory
        self.readDiagnosis = readDiagnosis
        self.samplingAllowed = samplingAllowed
    }

    @MainActor func start() {
        guard samplingAllowed(), lifetime.current() == nil else { return }
        let token = lifetime.start()
        queue.async {
            guard self.lifetime.accepts(token) else { return }
            self.memory = self.readHistory?() ?? self.history.records(since: Date().addingTimeInterval(-6 * 3600))
            let snapshot = self.memory
            DispatchQueue.main.async { if self.lifetime.accepts(token) { self.recent = snapshot } }
            self.reschedule()
        }
    }

    /// Cancel first, then drain the serial reader; an old publication cannot reach a new session.
    @MainActor func beginStopping() { lifetime.stop() }
    @MainActor func stop() async {
        beginStopping()
        await withCheckedContinuation { done in
            queue.async {
                self.timer?.cancel(); self.timer = nil; self.interval = 0
                self.memory = []
                done.resume()
            }
        }
        if lifetime.current() == nil { recent = []; diagnosis = nil }
    }

    /// Every 60 s on power, 300 s on battery.
    private func reschedule() {
        guard samplingAllowed(), let token = lifetime.current() else { return }
        let onBattery = Battery.read().map { !$0.externalPower } ?? false
        let every: TimeInterval = onBattery ? 300 : 60
        guard every != interval else { return }
        interval = every
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: every, leeway: .seconds(5))
        t.setEventHandler { [weak self] in self?.tick(token: token) }
        t.resume()
        timer = t
    }

    private func tick(token: UUID) {
        guard samplingAllowed(), lifetime.accepts(token) else { return }
        let pulse = sampler.sample()
        let record = PulseRecord(pulse)
        history.append(record)
        let now = Date()
        memory.append(record)
        memory.removeAll { now.timeIntervalSince($0.t) > 6 * 3600 }
        let snapshot = memory
        DispatchQueue.main.async { if self.lifetime.accepts(token) { self.recent = snapshot } }
        if now.timeIntervalSince(lastProgramRecord) >= 290 {
            lastProgramRecord = now
            let inventory = MemoryInventory.collect()
            if inventory.available {
                programHistory.append(ProgramMemoryRecord(inventory.programs.map(\.historyEntry), at: now), now: now)
            }
        }

        let enabled = UserDefaults.standard.object(forKey: Self.alertsKey) as? Bool ?? true
        let found = diagnose(token: token)
        var fired = alerts.evaluate(memory.filter { now.timeIntervalSince($0.t) <= 15 * 60 }, latest: pulse, now: now)
        // One memory notification: the diagnosis names the culprit, the older rules only the biggest program.
        if found.memoryStrain == .exhausted { fired.removeAll { $0.key == "swap" || $0.key == "memory" } }
        fired += alerts.evaluate(found, now: now)
        if enabled, lifetime.accepts(token) { for a in fired { notify(a) } }
        reschedule()
    }

    /// Runs on `queue`.
    @discardableResult private func diagnose(token: UUID) -> SlowdownDiagnosis {
        // Snapshots of the Overview card need a diagnosis with culprits even on a calm Mac.
        let fixture = ProcessInfo.processInfo.environment["THERMO_DIAGNOSIS_FIXTURE"]
            .flatMap { FileManager.default.contents(atPath: $0) }
            .flatMap { try? JSONDecoder().decode(SlowdownDiagnosis.self, from: $0) }
        let found = fixture ?? readDiagnosis?().0 ?? SlowdownDiagnosis.diagnose(slowdown.sample(), system: .read())
        DispatchQueue.main.async {
            if self.samplingAllowed(), self.lifetime.accepts(token) { self.diagnosis = found }
        }
        return found
    }

    /// A fresh answer now, e.g. after ending a culprit.
    func diagnoseNow() {
        guard samplingAllowed(), let token = lifetime.current() else { return }
        queue.async {
            guard self.samplingAllowed(), self.lifetime.accepts(token) else { return }
            self.diagnose(token: token)
        }
    }

    /// A fresh answer handed to `then` on the recorder's queue, with the processes it was made from.
    /// It reuses the long-lived sampler, so busy streaks and idle times are judged as on every tick.
    /// `onSkipped` also runs on the recorder queue, so an admitted caller can release its operation.
    func diagnoseFresh(onSkipped: @escaping () -> Void = {},
                       then: @escaping (SlowdownDiagnosis, [SlowdownProcess]) -> Void) {
        let token = samplingAllowed() ? lifetime.current() : nil
        queue.async {
            guard let token, self.samplingAllowed(), self.lifetime.accepts(token) else { onSkipped(); return }
            let processes: [SlowdownProcess]
            let found: SlowdownDiagnosis
            if let read = self.readDiagnosis { (found, processes) = read() }
            else {
                processes = self.slowdown.sample()
                found = SlowdownDiagnosis.diagnose(processes, system: .read())
            }
            guard self.samplingAllowed(), self.lifetime.accepts(token) else { onSkipped(); return }
            DispatchQueue.main.async {
                if self.samplingAllowed(), self.lifetime.accepts(token) { self.diagnosis = found }
            }
            then(found, processes)
        }
    }

    private func notify(_ a: SlowdownAlerts.Alert) {
        // UserNotifications throws outside an app bundle (bare dev builds).
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = a.title
        content.body = a.body
        content.userInfo = ["program": a.program ?? ""]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "thermo.slowdown.\(a.key)", content: content, trigger: nil))
    }
}

/// The Overview's look back: load per core over the last hour or six, tap a moment to see who
/// was on top then.
struct PulseHistoryChart: View {
    @ObservedObject var recorder = PulseRecorder.shared
    @State private var hours = 1
    @State private var picked: PulseRecord?

    var records: [PulseRecord] {
        let since = Date().addingTimeInterval(-Double(hours) * 3600)
        return recorder.recent.filter { $0.t >= since }
    }

    var body: some View {
        if recorder.recent.count >= 2 {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(tr("Load, last %1$@ h", String(hours))).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $hours) { Text("1h").tag(1); Text("6h").tag(6) }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 80).controlSize(.mini)
                }
                Chart(records, id: \.t) { r in
                    AreaMark(x: .value("t", r.t), y: .value("load", r.load1 / Double(max(1, r.cores))))
                        .foregroundStyle(.orange.opacity(0.25))
                    LineMark(x: .value("t", r.t), y: .value("load", r.load1 / Double(max(1, r.cores))))
                        .foregroundStyle(.orange)
                    if let p = picked, p.t == r.t {
                        RuleMark(x: .value("t", p.t)).foregroundStyle(.secondary)
                    }
                }
                .chartYAxis(.hidden)
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisValueLabel(format: .dateTime.hour().minute()) } }
                .frame(height: 46)
                .chartOverlay { proxy in
                    GeometryReader { g in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onTapGesture { location in
                                let x = location.x - g[proxy.plotAreaFrame].origin.x
                                guard let date: Date = proxy.value(atX: x) else { return }
                                picked = records.min { abs($0.t.timeIntervalSince(date)) < abs($1.t.timeIntervalSince(date)) }
                            }
                    }
                }
                if let p = picked {
                    Text(caption(p)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .padding(.leading, 28)
        }
    }

    func caption(_ r: PulseRecord) -> String {
        let time = r.t.text(date: .omitted, time: .shortened)
        let who = r.top.map { p in
            p.cpu >= 50 ? "\(p.name) \(Int(p.cpu))%" : "\(p.name) \(MemoryFormat.string(kibibytes: p.memoryKB))"
        }.joined(separator: " · ")
        return tr("%1$@ · load %2$@ · %3$@", time, String(Int(r.load1.rounded())), who)
    }
}
