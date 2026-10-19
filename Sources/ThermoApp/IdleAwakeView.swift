import AgentCore
import AppKit
import CleanKit
import Foundation
import IOKit.ps
import SwiftUI
import ThermoL10n

@MainActor final class IdleAwakeModel: ObservableObject {
    static let shared = IdleAwakeModel()
    @Published private(set) var state: IdleAwakeState
    @Published private(set) var issue: String?
    var onStateChange: (() -> Void)?
    private let controller: IdleAwakeController
    private let readPower: () -> IdleAwakePower
    private let now: () -> Date
    private let automaticallyMonitor: Bool
    private let record: (OperationRecord) -> Void
    private var viewers = 0
    private var timer: Timer?
    private var powerSource: CFRunLoopSource?
    private var activity: NSObjectProtocol?

    init(controller: IdleAwakeController? = nil, power: @escaping () -> IdleAwakePower = { .read() },
         now: @escaping () -> Date = { Date() }, automaticallyMonitor: Bool = true,
         record: @escaping (OperationRecord) -> Void = { OperationJournal.record($0) }) {
        self.controller = controller ?? IdleAwakeController(); self.readPower = power; self.now = now
        self.automaticallyMonitor = automaticallyMonitor; self.record = record
        state = self.controller.inspect(power: power(), now: now())
    }
    deinit {
        timer?.invalidate()
        if let powerSource { CFRunLoopSourceInvalidate(powerSource) }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }
    var canStart: Bool { !state.requested && state.power.allowsStart }
    var canStop: Bool { state.requested }
    func open() { viewers += 1; refresh() }
    func close() { viewers = max(0, viewers - 1); updateMonitoring() }
    func inspect() -> IdleAwakeState { controller.inspect(power: readPower(), now: now()) }
    func start(mode: IdleAwakeMode, seconds: Double?) {
        guard IdleAwakeController.validDuration(seconds) else {
            issue = "Duration must be 1…604800 seconds or manual."; return
        }
        var intent = IdleAwakeState(); intent.mode = mode; intent.expiresAt = seconds.map { now().addingTimeInterval($0) }
        do { try controller.start(mode: mode, seconds: seconds, power: readPower(), now: now()); issue = nil; log("idleAwakeStart", "done", configuration: intent) }
        catch { issue = error.localizedDescription; log("idleAwakeStart", "failed", configuration: intent) }
        state = controller.inspect(power: readPower(), now: now()); updateMonitoring()
    }
    func stop() {
        let before = controller.state
        controller.stop(now: now()); state = controller.inspect(power: readPower(), now: now()); issue = state.issue
        log("idleAwakeStop", state.requested ? "unconfirmed" : "done", configuration: before); updateMonitoring()
    }
    func refresh() {
        let before = controller.state
        controller.tick(power: readPower(), now: now())
        state = controller.inspect(power: readPower(), now: now()); issue = state.issue
        if before.phase != state.phase {
            let action = state.phase == .active ? "idleAwakeResume" : [IdleAwakeState.Phase.idle, .ending].contains(state.phase) ? "idleAwakeEnd" : "idleAwakePause"
            log(action, state.phase == .ending ? "unconfirmed" : "done", configuration: before)
        }
        updateMonitoring()
    }
    private func log(_ action: String, _ status: String, configuration: IdleAwakeState) {
        let partial = status == "unconfirmed" || (status == "failed" && controller.state.phase == .ending)
        let itemStatus = partial ? "partial" : status
        let outcome = partial ? "partial" : status == "failed" ? "failed" : "succeeded"
        var details: [String] = []
        if let mode = configuration.mode {
            details.append(tr(mode == .tasks ? "Keep tasks running" : mode == .display ? "Keep display on" : "Keep display and tasks awake"))
        }
        details.append(configuration.expiresAt.map { tr("Ends at %1$@", $0.formatted(date: .omitted, time: .standard)) } ?? tr("Until I stop it"))
        if let issue = controller.state.issue ?? issue { details.append(tr(issue)) }
        if controller.state.lastEndReason == "expired" { details.append(tr("The timer ended this session.")) }
        record(OperationRecord(feature: "power", action: action, outcome: outcome,
            items: [.init(target: tr("Keep awake"), status: itemStatus, detail: details.joined(separator: " · "))]))
    }
    private func updateMonitoring() {
        onStateChange?()
        guard automaticallyMonitor else { return }
        if state.requested {
            if activity == nil { activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "User-requested Thermo idle-awake session") }
            if timer == nil {
                let next = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
                timer = next; RunLoop.main.add(next, forMode: .common)
            }
        } else {
            timer?.invalidate(); timer = nil
            if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        }
        if state.requested || viewers > 0 {
            if powerSource == nil {
                powerSource = IOPSNotificationCreateRunLoopSource({ context in
                    guard let context else { return }
                    let model = Unmanaged<IdleAwakeModel>.fromOpaque(context).takeUnretainedValue()
                    MainActor.assumeIsolated { model.refresh() }
                }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
                if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
            }
        } else if let powerSource { CFRunLoopSourceInvalidate(powerSource); self.powerSource = nil }
    }
    func controlValues() -> [String: String] {
        let observed = inspect()
        var values = ["phase": observed.phase.rawValue, "requested": String(observed.requested), "requestCount": String(observed.requestCount),
                      "powerSource": observed.power.source.rawValue, "observedAt": ISO8601DateFormatter().string(from: observed.observedAt), "requiresHelper": "false"]
        if let mode = observed.mode { values["mode"] = mode.rawValue }
        if let end = observed.expiresAt { values["expiresAt"] = ISO8601DateFormatter().string(from: end) }
        if let percent = observed.power.percent { values["batteryPercent"] = String(percent) }
        if let reason = observed.lastEndReason { values["lastEndReason"] = reason }
        if let issue = observed.issue ?? issue { values["issue"] = issue }
        return values
    }
}

struct IdleAwakeButton: View {
    @ObservedObject private var model = IdleAwakeModel.shared
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: {
            Label(tr(model.state.requested ? "Keep awake · session configured" : "Keep awake"), systemImage: "cup.and.saucer")
        }.sheet(isPresented: $showing) { IdleAwakePanel(model: model) }
    }
}
struct IdleAwakePanel: View {
    @ObservedObject var model: IdleAwakeModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode = IdleAwakeMode.both
    @State private var seconds = 3600
    private func modeLabel(_ mode: IdleAwakeMode) -> String {
        switch mode { case .display: return tr("Keep display on"); case .tasks: return tr("Keep tasks running"); case .both: return tr("Keep display and tasks awake") }
    }
    private var status: String {
        switch model.state.phase {
        case .idle: return tr("Keep awake is off.")
        case .active: return tr("Keep awake is on.")
        case .pausedLowBattery: return tr("Paused at 20% battery or below. Connect power to resume.")
        case .pausedPowerUnknown: return tr("Paused because power status could not be verified.")
        case .ending: return tr("Checking that keep awake has ended…")
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(tr("Keep awake"), systemImage: "cup.and.saucer").font(.title2.weight(.semibold))
            Text(tr("Prevents idle sleep. Lid-close and manual sleep follow macOS rules. Closing this panel keeps the session running; quitting Thermo ends it."))
                .font(.callout).foregroundStyle(.secondary)
            Text(status).font(.headline).foregroundStyle(model.state.phase == .active ? Color.primary : model.state.phase == .idle ? Color.secondary : Color.orange)
            if !model.state.requested, !model.state.power.allowsStart {
                Text(tr("Idle awake needs known power status and more than 20% battery, or external power.")).font(.callout).foregroundStyle(.orange)
            }
            if let end = model.state.expiresAt {
                Text(tr("Ends at %1$@", end.formatted(date: .omitted, time: .standard))).monospacedDigit()
            }
            if model.state.phase == .idle, let reason = model.state.lastEndReason {
                Text(tr(reason == "expired" ? "The timer ended this session." : ["requestLost", "renewFailed"].contains(reason) ? "macOS ended this awake session. Start a new session if needed." : "This session has ended.")).font(.caption).foregroundStyle(.secondary)
            }
            if model.state.requested { Text(tr("The timer continues while paused.")).font(.caption).foregroundStyle(.secondary) }
            if let issue = model.issue ?? model.state.issue { Text(tr(issue)).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            if !model.state.requested {
              Picker(tr("Awake mode"), selection: $mode) {
                ForEach(IdleAwakeMode.allCases, id: \.self) { Text(modeLabel($0)).tag($0) }
              }
              Picker(tr("Duration"), selection: $seconds) {
                ForEach([900, 1800, 3600, 7200, 14400, 28800], id: \.self) { Text(trCount($0 / 60, "%1$@ minute", "%1$@ minutes")).tag($0) }
                Text(tr("Until I stop it")).tag(0)
              }
            } else if let selected = model.state.mode { Text(modeLabel(selected)) }
            Text(tr("At 20% battery or below, Thermo pauses until power is connected. Other apps may still keep this Mac awake."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(tr("Refresh")) { model.refresh() }
                Spacer()
                Button(tr("Start keeping awake")) { model.start(mode: mode, seconds: seconds == 0 ? nil : Double(seconds)) }.disabled(!model.canStart)
                Button(tr("Stop keeping awake")) { model.stop() }.disabled(!model.canStop)
                Button(tr("Close")) { dismiss() }
            }
        }.padding(24).frame(width: 550)
            .onAppear { model.open() }.onDisappear { model.close() }
    }
}
