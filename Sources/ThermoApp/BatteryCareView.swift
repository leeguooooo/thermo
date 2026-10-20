import AppKit
import CoreFoundation
import CleanKit
import SwiftUI
import ThermoKit
import ThermoL10n

struct BatteryCareBackend: Sendable {
    var read: @Sendable () async throws -> BatteryChargeState
    var set: @Sendable (BatteryChargePolicy, String) async throws -> Void
    var reset: @Sendable () -> Void
    var probe: @Sendable () async -> BatteryChargeProbe? = { nil }
    var record: @Sendable (String, String, String?) -> Void = { _, _, _ in }
    var flush: @Sendable () async -> Void = {}
    static func live() -> Self {
        let client = HelperClient(), history = DispatchQueue(label: "dev.thermo.charging.history", qos: .utility)
        return .init(read: { try await client.batteryChargeState() }, set: { try await client.setBatteryChargePolicy($0, sessionID: $1) }, reset: { client.reset() }, probe: { await Task.detached(priority: .utility) { BatteryChargeProbe.live() }.value }, record: { action, status, detail in
            let entry = OperationRecord(feature: "battery", action: action, items: [.init(target: "charging", status: status, detail: detail)])
            history.async { OperationJournal.record(entry) }
        }, flush: { await withCheckedContinuation { continuation in history.async { continuation.resume() } } })
    }
}

@MainActor struct BatteryCarePreferences {
    static let key = "batteryChargeLimit80Enabled"
    var load: () -> Bool
    var save: (Bool) -> Void
    static func defaults(_ defaults: UserDefaults = .standard) -> Self {
        .init(load: {
            guard let value = defaults.object(forKey: key) as? NSNumber,
                  CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
            return value.boolValue
        }, save: { defaults.set($0, forKey: key) })
    }
}

/// End only charging sheets after readback and journal completion. AppKit may
/// ignore terminate while a sheet is still attached. Other features' dialogs
/// remain governed by AppExitGuard.
@MainActor private enum BatteryCareExit {
    final class Entry {
        weak var window: NSWindow?
        let dismiss: () -> Void
        init(_ window: NSWindow, _ dismiss: @escaping () -> Void) { self.window = window; self.dismiss = dismiss }
    }
    static var entries: [UUID: Entry] = [:]
    static func terminate() {
        let current = Array(entries.values); entries.removeAll()
        for entry in current {
            entry.dismiss()
            if let window = entry.window, window.sheetParent != nil { NSApp.endSheet(window) }
        }
        NSApp.terminate(nil)
    }
}
@MainActor private struct BatteryCareExitMarker: NSViewRepresentable {
    var dismiss: () -> Void
    final class Marker: NSView {
        let token = UUID()
        var dismiss: () -> Void = {}
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            bind()
        }
        func bind() {
            BatteryCareExit.entries[token] = window.map { BatteryCareExit.Entry($0, dismiss) }
        }
    }
    func makeNSView(context: Context) -> Marker { let view = Marker(); view.dismiss = dismiss; return view }
    func updateNSView(_ view: Marker, context: Context) { view.dismiss = dismiss; view.bind() }
    static func dismantleNSView(_ view: Marker, coordinator: ()) { BatteryCareExit.entries[view.token] = nil }
}

@MainActor final class BatteryCareModel: ObservableObject {
    static let shared = BatteryCareModel()
    @Published private(set) var state: BatteryChargeState?
    @Published private(set) var probe: BatteryChargeProbe?
    @Published private(set) var busy = false
    @Published private(set) var issue: String?
    @Published private(set) var preferenceEnabled: Bool
    @Published private(set) var quitRequested = false
    private var sessionID: String?
    private var viewers = 0
    private var poll: Task<Void, Never>?
    private var launchChecked = false
    private var resumeOnNextRead = false
    private var launch: Task<Void, Never>?
    private let backend: BatteryCareBackend
    private let preferences: BatteryCarePreferences
    private let exit: @MainActor () -> Void
    init(backend: BatteryCareBackend = .live(), preferences: BatteryCarePreferences? = nil,
         exit: @escaping @MainActor () -> Void = { BatteryCareExit.terminate() }) {
        let preferences = preferences ?? .defaults()
        self.backend = backend; self.preferences = preferences; self.exit = exit
        preferenceEnabled = preferences.load()
    }
    deinit { launch?.cancel(); poll?.cancel(); backend.reset() }
    var needsQuitRecovery: Bool { sessionID != nil }
    var anotherOwner: Bool { state.map { $0.policy != .off && !$0.ownedByCaller && $0.sessionID != sessionID } ?? false }
    var lostSessionConnection: Bool { sessionID != nil && state?.sessionID == sessionID && state?.ownedByCaller == false }
    var canEnable: Bool { !busy && !quitRequested && !anotherOwner && state?.support == .smc && state?.percent != nil && state?.externalPower != nil && state?.phase != .recovering && state?.ownership != .uncertain && (state?.gate == .allowed || (state?.ownedByCaller == true && state?.gate == .inhibited)) }
    var canStop: Bool { !busy && (needsQuitRecovery || state?.ownedByCaller == true || state?.phase == .recovering) }
    var canDisablePreference: Bool { !busy && preferenceEnabled }
    var canChargeToFull: Bool { canEnable && state?.policy == .limit80 && state?.ownedByCaller == true && state?.externalPower == true && state?.percent.map({ $0 < 100 }) == true }
    func open() { viewers += 1; refresh() }
    func close() { viewers = max(0, viewers - 1); updatePolling() }
    func restoreSavedPreference() {
        guard !launchChecked else { return }; launchChecked = true
        guard preferenceEnabled else { return }
        if busy { resumeOnNextRead = true; return }
        busy = true
        launch = Task {
            await readLatest(); busy = false
            if !Task.isCancelled, canEnable { change(.limit80) } else { finish(allowStop: true) }
            launch = nil
        }
    }
    func refresh() {
        guard !busy else { return }; busy = true; issue = nil
        Task { await readLatest(); finish(allowStop: true) }
    }
    func change(_ policy: BatteryChargePolicy) {
        guard policy == .off ? (canStop || canDisablePreference) : (policy == .chargeToFull ? canChargeToFull : canEnable) else { return }
        if policy == .off {
            preferenceEnabled = false; preferences.save(false)
            if !canStop { return } // Disable startup preference without touching another owner.
        }
        perform(policy)
    }
    private func perform(_ policy: BatteryChargePolicy) {
        let previous = sessionID, id = sessionID ?? UUID().uuidString
        if policy != .off { sessionID = id }
        busy = true; issue = nil
        Task {
            do {
                try await backend.set(policy, id)
                if policy != .off { preferenceEnabled = true; preferences.save(true) }
                backend.record("charging-" + policy.rawValue, "done", nil)
            } catch {
                if error is BatteryChargeClientError, previous == nil { sessionID = nil }
                issue = error.localizedDescription
                backend.record("charging-" + policy.rawValue, "failed", issue)
            }
            await readLatest(); finish(allowStop: policy != .off)
        }
    }
    func requestQuit() -> Bool {
        launch?.cancel()
        resumeOnNextRead = false
        if quitRequested { return true }
        guard needsQuitRecovery else { return false }
        quitRequested = true
        if !busy { perform(.off) }
        return true
    }
    private func readLatest() async {
        do {
            let value = try await backend.read(); state = value; probe = nil
            let previous = sessionID
            if value.ownedByCaller { sessionID = value.sessionID }
            else if value.policy == .off && value.phase == .off && value.ownership == .none { sessionID = nil }
            else if let other = value.sessionID, other != sessionID { sessionID = nil }
            if previous != nil, sessionID == nil { issue = nil; backend.record("charging-recovery", "done", nil) }
        } catch { state = nil; issue = error.localizedDescription; probe = await backend.probe() }
    }
    private func finish(allowStop: Bool) {
        busy = false
        if quitRequested, !needsQuitRecovery {
            busy = true; updatePolling()
            Task { await backend.flush(); busy = false; quitRequested = false; exit() }
            return
        }
        if quitRequested, allowStop { perform(.off); return }
        if resumeOnNextRead {
            resumeOnNextRead = false
            if preferenceEnabled, !quitRequested, sessionID == nil, canEnable { change(.limit80); return }
        }
        updatePolling()
    }
    private var shouldPoll: Bool { needsQuitRecovery || (viewers > 0 && state.map { $0.phase != .off } == true) }
    private func updatePolling() {
        guard shouldPoll else { poll?.cancel(); poll = nil; return }
        guard poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let model = self, model.shouldPoll else { self?.poll = nil; return }
                if !model.busy { model.busy = true; await model.readLatest(); model.finish(allowStop: false) }
            }
        }
    }
}

struct BatteryCareButton: View {
    @State private var showing = false
    @ObservedObject private var model = BatteryCareModel.shared
    var body: some View {
        Button { showing = true } label: {
            FeatureRow(title: tr("Battery charging protection"), symbol: "battery.75")
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showing) { BatteryCarePanel(model: model) }
    }
}

struct BatteryCarePanel: View {
    @ObservedObject var model: BatteryCareModel
    @Environment(\.dismiss) private var dismiss
    var configureHelper: () -> Void = { AppModels.shared.monitor.installHelper() }
    var openBatterySettings: () -> Void = {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") { NSWorkspace.shared.open(url) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(tr("Battery charging protection"), systemImage: "battery.75").font(Theme.heading)
            Text(tr("Pause charging at 80% and allow it again below 75%. The Mac can continue using external power.")).font(Theme.secondary).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            if let state = model.state {
                if let support = supportText(state.support ?? .unknown) { Text(support).font(Theme.secondary).foregroundStyle(Theme.textSecondary) }
                if state.support == nil { Button(tr("Set up or update Thermo's helper"), action: configureHelper) }
                Text(status(state)).font(Theme.rowTitle.weight(.semibold))
                if let reason = state.lastFullChargeEndReason { Text(endedText(reason)).font(Theme.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true) }
                if let percent = state.percent { Text(tr("Observed battery: %1$@%%", String(format: "%.0f", percent))).monospacedDigit() }
                if state.support == .smc || model.needsQuitRecovery { Text(tr(gateText(state))).font(Theme.caption).foregroundStyle(Theme.textTertiary) }
                if model.anotherOwner { Text(tr("Another Thermo process owns this charging policy.")).font(Theme.caption).foregroundStyle(Theme.caution) }
                if model.lostSessionConnection { Text(tr("The charging connection was lost. Recovery still needs confirmation.")).font(Theme.caption).foregroundStyle(Theme.caution) }
                if let error = state.error { Text(tr(error)).font(Theme.caption).foregroundStyle(Theme.caution).fixedSize(horizontal: false, vertical: true) }
            } else {
                Text(tr("Charging control has not been verified.")).foregroundStyle(Theme.caution)
                if let support = model.probe?.support, support != .smc, support != .unknown {
                    if let detail = supportText(support) { Text(detail).font(Theme.secondary).foregroundStyle(Theme.textSecondary) }
                } else { Button(tr("Set up or update Thermo's helper"), action: configureHelper) }
            }
            if let issue = model.issue, issue != model.state?.error, fallbackSupport == nil { Text(tr(issue)).font(Theme.caption).foregroundStyle(Theme.caution).fixedSize(horizontal: false, vertical: true) }
            if model.preferenceEnabled { Text(tr("The 80% preference is saved. Thermo checks support before resuming it at startup. Opening this panel only checks status.")).font(Theme.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true) }
            Text(tr("Temporary full charge ends at a reported 100%, without external power, or when power state is unavailable. A previously active 80% preference is retained. System protection still applies.")).font(Theme.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            if model.quitRequested { Text(tr("Waiting for charging recovery before quitting. Retry if recovery remains unconfirmed.")).foregroundStyle(Theme.caution).font(Theme.body) }
            HStack {
                Button(tr(model.state?.policy == .chargeToFull ? "Resume 80% limit" : "Enable 80% limit")) { model.change(.limit80) }.disabled(!model.canEnable)
                Button(tr("Charge to 100%")) { model.change(.chargeToFull) }.disabled(!model.canChargeToFull)
                Button(tr(model.canStop ? "Turn off and restore charging" : "Disable saved 80% preference")) { model.change(.off) }.disabled(!model.canStop && !model.canDisablePreference)
            }
            HStack {
                Button(tr("Refresh")) { model.refresh() }.disabled(model.busy)
                if (model.state?.support ?? model.probe?.support) != .noInternalBattery { Button(tr("Open Battery settings"), action: openBatterySettings) }
                if model.busy { ProgressView().controlSize(.small) }
                Spacer(); Button(tr("Close")) { dismiss() }
            }
        }.padding(24).frame(width: 600)
            .background(BatteryCareExitMarker(dismiss: { dismiss() }).frame(width: 0, height: 0))
            .onAppear { model.open() }.onDisappear { model.close() }
    }
    private var fallbackSupport: BatteryChargeSupport? {
        guard model.state == nil, !model.needsQuitRecovery, let support = model.probe?.support,
              [.systemSettings, .unsupported, .noInternalBattery].contains(support) else { return nil }
        return support
    }
    private func supportText(_ support: BatteryChargeSupport) -> String? {
        switch support {
        case .smc: return nil
        case .noInternalBattery: return tr("No internal battery was reported by this Mac.")
        case .systemSettings: return tr("Manage the system charging limit in Battery settings.")
        case .unsupported: return tr("No supported charging control was found on this Mac.")
        case .unknown: return tr("Charging support has not been verified.")
        }
    }
    private func endedText(_ reason: BatteryFullChargeEndReason) -> String {
        switch reason {
        case .fullyCharged: return tr("A 100% reading ended the temporary full-charge request.")
        case .unplugged: return tr("The temporary full-charge request ended because external power was not connected.")
        case .observationUnavailable: return tr("The temporary full-charge request ended because fresh power state was unavailable.")
        case .supportChanged: return tr("Charging support changed; the temporary full-charge request ended.")
        }
    }
    private func status(_ state: BatteryChargeState) -> String {
        switch state.phase {
        case .holding: return tr("Charging pause confirmed")
        case .watching: return tr(state.policy == .chargeToFull ? "Charge-to-full preference active" : "80% limit active; charging is allowed")
        case .off: return tr("Thermo charging protection is off")
        case .blocked: return tr("Charging control needs attention")
        case .recovering: return tr("Restoring Thermo's charging control…")
        }
    }
    private func gateText(_ state: BatteryChargeState) -> String {
        switch state.gate {
        case .allowed: return "Charging is allowed. This does not mean the battery is currently charging."
        case .inhibited: return state.ownership == .owned ? "Thermo's pause is confirmed." : "Charging is paused outside this Thermo connection."
        case .unknown: return "The charging gate could not be verified."
        }
    }
}
